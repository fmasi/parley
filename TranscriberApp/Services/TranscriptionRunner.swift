import Foundation
import os
import TranscriberCore

struct TranscriptionResult {
    let jsonPath: URL
}

@MainActor
final class TranscriptionRunner {
    enum RunnerError: LocalizedError {
        case engineNotReady(String)
        case engineUnavailable(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .engineNotReady(let name):
                return "Engine '\(name)' is not ready. It may need to download a model first."
            case .engineUnavailable(let name):
                return "Engine '\(name)' is not available on this version of macOS."
            case .failed(let msg):
                return msg
            }
        }
    }

    private var transcriber: (any TranscriptionEngine)?
    private var lastEngineID: EngineID?
    private var diarizer: (any DiarizationProvider)? = FluidAudioDiarizer()
    private let vadSpeechMap = VadSpeechMap()

    private(set) var chunkRotator: ChunkRotator?
    private(set) var chunkProcessor: ChunkProcessor?

    private let wavHeaderSize = 44
    private var detectedLanguages: [String] = []

    func run(
        systemAudio: URL,
        micAudio: URL?,
        outputDirectory: URL,
        config: Config,
        provenance: CaptureProvenance? = nil
    ) async throws -> TranscriptionResult {
        let startTime = ContinuousClock.now
        detectedLanguages = []

        let engineID = config.engine
        if transcriber == nil || lastEngineID != engineID {
            Logger.transcription.info("Creating engine: \(engineID.descriptor.displayName, privacy: .public)")
            transcriber = try createEngine(for: engineID, config: config)
            lastEngineID = engineID
        }

        guard let transcriber = transcriber else {
            throw RunnerError.failed("Failed to initialize transcription engine")
        }

        let isDualStream = micAudio != nil
        let segments: [(system: URL, mic: URL)]
        if let micAudio {
            segments = Self.discoverSegments(systemAudio: systemAudio, micAudio: micAudio)
        } else {
            // No mic — create tuples with system-only URLs (mic will be skipped below)
            segments = Self.discoverSegments(systemAudio: systemAudio, micAudio: systemAudio)
        }
        // Repair any orphaned segment whose header was never finalized (writer killed
        // mid-recording) so the recovered PCM is decodable — the chunked path repairs in
        // ChunkProcessor, this is the single-file / crash-recovery / CLI path (#85).
        repairSegmentHeaders(segments)
        var allSegments: [LabeledSegment] = []
        var audioPaths: [URL] = []
        var localSpeakerDb: [String: [Float]] = [:]
        var remoteSpeakerDb: [String: [Float]] = [:]
        // #93: every segment that actually contributed audio, so each (not just the base pair)
        // is archived to its own AAC and reflected in the transcript's audio_paths.
        var contributingPairs: [AudioArchiver.SegmentPair] = []

        for (index, segmentPair) in segments.enumerated() {
            if index > 0 {
                Logger.transcription.info("Transcribing recovery segment \(index + 1)")
            }

            let systemResult = try await transcribeStream(
                audioPath: segmentPair.system,
                source: "remote",
                transcriber: transcriber,
                label: "system\(index > 0 ? "-\(index + 1)" : "")",
                audioSource: .system,
                config: config
            )
            allSegments.append(contentsOf: systemResult.segments)
            remoteSpeakerDb.merge(systemResult.speakerDatabase) { existing, new in existing + new }
            audioPaths.append(segmentPair.system)

            var segmentMic: URL?
            if isDualStream {
                let micPath = segmentPair.mic
                if FileManager.default.fileExists(atPath: micPath.path) {
                    let micResult = try await transcribeStream(
                        audioPath: micPath,
                        source: "local",
                        transcriber: transcriber,
                        label: "mic\(index > 0 ? "-\(index + 1)" : "")",
                        audioSource: .microphone,
                        config: config
                    )
                    allSegments.append(contentsOf: micResult.segments)
                    localSpeakerDb.merge(micResult.speakerDatabase) { existing, new in existing + new }
                    audioPaths.append(micPath)
                    segmentMic = micPath
                }
            }

            // #93: record this segment for archival if it carried real audio (system payload
            // past the WAV header, or a mic file existed). Skips header-only orphans.
            let sysSize = (try? FileManager.default.attributesOfItem(atPath: segmentPair.system.path)[.size] as? Int) ?? 0
            if sysSize > wavHeaderSize || segmentMic != nil {
                contributingPairs.append(AudioArchiver.SegmentPair(system: segmentPair.system, mic: segmentMic))
            }
        }

        if isDualStream && !allSegments.isEmpty {
            SpeakerAssignment.tagWithSourcePrefix(&allSegments)
        }

        allSegments.sort { $0.start < $1.start }
        Logger.transcription.info("Total segments after merge: \(allSegments.count, privacy: .public)")

        // Echo dedup (remove mic bleed of remote speaker)
        var echoRemoved = 0
        if isDualStream {
            let dedupResult = EchoDeduplicator.deduplicate(
                segments: allSegments,
                localSpeakerDatabase: localSpeakerDb,
                remoteSpeakerDatabase: remoteSpeakerDb,
                temporalThreshold: config.echoTemporalThreshold,
                textThreshold: config.echoTextThreshold,
                embeddingThreshold: config.echoEmbeddingThreshold
            )
            allSegments = dedupResult.segments
            echoRemoved = dedupResult.removedCount
        }

        let uniqueLanguages = Set(detectedLanguages)
        let detectedLanguage: String
        switch uniqueLanguages.count {
        case 0: detectedLanguage = "auto"
        case 1: detectedLanguage = uniqueLanguages.first!
        default: detectedLanguage = "multilingual"
        }

        let json = TranscriptAssembler.assemble(
            segments: allSegments,
            audioPaths: audioPaths,
            outputFormat: config.outputFormat,
            language: detectedLanguage,
            numSpeakers: nil,
            diarization: diarizer != nil,
            dualStream: isDualStream,
            echoSegmentsRemoved: echoRemoved,
            provenance: provenance,
            // No in-memory session start here (CLI / crash-recovery / single-file path), so
            // use the source audio's creation time as the recording-start stamp (#49).
            recordedAt: (try? systemAudio.resourceValues(forKeys: [.creationDateKey]).creationDate)
        )

        let baseName = systemAudio.deletingPathExtension().lastPathComponent
        let jsonPath = outputDirectory.appendingPathComponent(baseName + ".json")
        try TranscriptAssembler.write(json, to: jsonPath)

        do {
            try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)
        } catch {
            Logger.files.error("Failed to write format file: \(error, privacy: .public)")
        }

        // #93: archive EVERY contributing segment to its own stereo AAC (L=mic, R=system),
        // not just the base pair — a crash-recovered recording has multiple segments and the
        // pre-#93 code silently dropped all but the first. archiveAll is per-segment isolated:
        // a failed segment keeps its WAV rather than aborting the whole archive.
        if isDualStream && !contributingPairs.isEmpty {
            let archived = await AudioArchiver.archiveAll(
                pairs: contributingPairs,
                outputDirectory: outputDirectory,
                bitrateKbps: config.archiveBitrateKbps
            )
            TranscriptAssembler.reconcileAudioPaths(in: jsonPath, to: archived)
            Logger.files.info("Archived \(archived.count, privacy: .public) segment(s)")

            do {
                try StorageManager.enforceQuota(
                    in: outputDirectory,
                    limitHours: config.audioArchiveLimitHours,
                    bitrateKbps: config.archiveBitrateKbps,
                    protectedFile: archived.last
                )
            } catch {
                Logger.files.error("Quota enforcement failed: \(error, privacy: .public)")
            }
        }

        let elapsed = ContinuousClock.now - startTime
        Logger.transcription.info("Transcription pipeline complete — \(elapsed.components.seconds)s, output: \(jsonPath.lastPathComponent, privacy: .private)")

        return TranscriptionResult(jsonPath: jsonPath)
    }

    /// Finalize a chunked recording session: reconcile speakers, merge chunks, write transcript.
    func finalize(
        sessionState: SessionState,
        outputDirectory: URL,
        config: Config
    ) async throws -> TranscriptionResult {
        let startTime = ContinuousClock.now

        // 1. Speaker reconciliation — chunks must be in recording order so the reconciler's
        // greedy cosine matching builds reference embeddings chronologically. (#56)
        let sortedChunks = sessionState.chunks.sorted { $0.index < $1.index }
        Logger.transcription.info("Reconciling speakers across \(sortedChunks.count) chunks (cosine threshold: 0.65)")
        let speakerMapping = SpeakerReconciler.reconcile(
            chunks: sortedChunks,
            threshold: 0.65
        )

        // 2. Merge chunks
        let mergeResult = TranscriptMerger.merge(
            chunks: sortedChunks,
            speakerMapping: speakerMapping,
            meetingStart: sessionState.meetingStart
        )

        // 3. Convert MergedSegments to LabeledSegments for existing assembler
        var allSegments: [LabeledSegment] = []
        for chunk in sortedChunks {
            let chunkOffset = chunk.startTime.timeIntervalSince(sessionState.meetingStart)
            let chunkMapping = speakerMapping[chunk.index] ?? [:]
            for seg in chunk.segments {
                let elapsed = chunkOffset + seg.start
                let elapsedEnd = chunkOffset + seg.end
                let globalSpeaker = chunkMapping[seg.speaker] ?? seg.speaker
                allSegments.append(LabeledSegment(
                    start: elapsed,
                    end: elapsedEnd,
                    speaker: globalSpeaker,
                    text: seg.text,
                    source: seg.source,
                    confidence: seg.qualityScore
                ))
            }
        }
        allSegments.sort { $0.start < $1.start }

        // 4. Dual-stream tagging
        let isDualStream = allSegments.contains { $0.source == "local" }
        if isDualStream {
            SpeakerAssignment.tagWithSourcePrefix(&allSegments)
        }

        // 5. Audio paths from chunks — must be in index order so AudioConcatenator
        // stitches them chronologically. (#56)
        let chunkAudioPaths = sortedChunks.map {
            outputDirectory.appendingPathComponent($0.audioPath)
        }

        // 5b. Concatenate chunk audio files into a single archive (if enabled and more than 1 chunk)
        let audioPaths: [URL]
        if config.mergeChunkedAudio && chunkAudioPaths.count > 1 {
            do {
                let concatResult = try await AudioConcatenator.concatenate(
                    sources: chunkAudioPaths,
                    outputDirectory: outputDirectory,
                    outputName: sessionState.sessionId
                )
                audioPaths = [concatResult.outputPath]
                Logger.files.info(
                    "Concatenated \(chunkAudioPaths.count, privacy: .public) chunks → \(concatResult.outputPath.lastPathComponent, privacy: .private) (passthrough: \(concatResult.usedPassthrough, privacy: .public))"
                )
            } catch {
                // concatenate() only deletes sources after a verified successful export,
                // so on throw the chunk files are still intact.
                Logger.files.error("Audio concatenation failed (\(type(of: error), privacy: .public)), keeping separate files: \(error, privacy: .public)")
                audioPaths = chunkAudioPaths
            }
        } else {
            audioPaths = chunkAudioPaths
        }

        // 6. Language detection
        let languages = Set(allSegments.compactMap(\.language))
        let detectedLanguage: String
        switch languages.count {
        case 0: detectedLanguage = "auto"
        case 1: detectedLanguage = languages.first!
        default: detectedLanguage = "multilingual"
        }

        // 7. Assemble JSON
        let totalEchoRemoved = sessionState.chunks.reduce(0) { $0 + $1.echoSegmentsRemoved }
        let json = TranscriptAssembler.assemble(
            segments: allSegments,
            audioPaths: audioPaths,
            outputFormat: config.outputFormat,
            language: detectedLanguage,
            numSpeakers: nil,
            diarization: true,
            dualStream: isDualStream,
            echoSegmentsRemoved: totalEchoRemoved,
            provenance: sessionState.provenance,
            // The wall-clock time the meeting actually began (#49).
            recordedAt: sessionState.meetingStart
        )

        let baseName = sessionState.sessionId
        let jsonPath = outputDirectory.appendingPathComponent(baseName + ".json")
        try TranscriptAssembler.write(json, to: jsonPath)

        // 8. Write format file
        do {
            try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)
        } catch {
            Logger.files.error("Failed to write format file: \(error, privacy: .public)")
        }

        // 9. Storage quota enforcement
        do {
            try StorageManager.enforceQuota(
                in: outputDirectory,
                limitHours: config.audioArchiveLimitHours,
                bitrateKbps: config.archiveBitrateKbps,
                protectedFile: audioPaths.last
            )
        } catch {
            Logger.files.error("Quota enforcement failed: \(error, privacy: .public)")
        }

        // 10. Clean up session.json
        SessionState.delete(directory: outputDirectory)

        let elapsed = ContinuousClock.now - startTime
        Logger.transcription.info("Chunked pipeline finalized — \(elapsed.components.seconds)s, \(mergeResult.chunkCount) chunks, output: \(jsonPath.lastPathComponent, privacy: .private)")

        return TranscriptionResult(jsonPath: jsonPath)
    }

    // MARK: - Chunked Pipeline

    /// Set up chunked recording pipeline.
    func setupChunkedPipeline(
        captureClient: AudioCaptureClient,
        outputDirectory: URL,
        sessionBaseName: String,
        config: Config
    ) throws {
        let engineID = config.engine
        if transcriber == nil || lastEngineID != engineID {
            Logger.transcription.info("Creating engine: \(engineID.descriptor.displayName, privacy: .public)")
            transcriber = try createEngine(for: engineID, config: config)
            lastEngineID = engineID
        }

        guard let transcriber else {
            throw RunnerError.failed("Failed to initialize transcription engine")
        }

        let sessionState = SessionState(
            sessionId: sessionBaseName,
            meetingStart: Date(),
            engine: engineID.rawValue,
            chunkDurationMinutes: config.validatedChunkDuration,
            chunks: []
        )

        let processor = ChunkProcessor(
            config: config,
            outputDirectory: outputDirectory,
            sessionState: sessionState,
            transcriber: transcriber,
            diarizer: diarizer
        )
        self.chunkProcessor = processor

        let rotator = ChunkRotator(
            captureClient: captureClient,
            outputDirectory: outputDirectory.path,
            sessionBaseName: sessionBaseName,
            chunkDurationMinutes: config.validatedChunkDuration,
            startTime: Date()
        ) { [weak processor] chunk in
            processor?.processChunk(chunk)
        }
        self.chunkRotator = rotator
    }

    func startChunkRotation() {
        chunkRotator?.start()
    }

    func stopChunkRotation() {
        chunkRotator?.stop()
    }

    func teardownChunkedPipeline() {
        chunkRotator = nil
        chunkProcessor = nil
    }

    func setDiarizer(_ provider: any DiarizationProvider) {
        self.diarizer = provider
    }

    func disableDiarization() {
        self.diarizer = nil
    }

    // MARK: - Private

    static func discoverSegments(
        systemAudio: URL,
        micAudio: URL
    ) -> [(system: URL, mic: URL)] {
        TranscriberCore.discoverSegments(systemAudio: systemAudio, micAudio: micAudio)
    }

    private func createEngine(for id: EngineID, config: Config) throws -> any TranscriptionEngine {
        guard id.descriptor.isAvailableOnThisOS else {
            throw RunnerError.engineUnavailable(id.descriptor.displayName)
        }

        switch id {
        case .speechAnalyzer:
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                return SpeechAnalyzerEngine()
            }
            #endif
            throw RunnerError.engineUnavailable("SpeechAnalyzer requires macOS 26")

        case .fluidAudio:
            return FluidAudioEngine()
        }
    }

    private struct StreamResult {
        let segments: [LabeledSegment]
        let speakerDatabase: [String: [Float]]
    }

    private func transcribeStream(
        audioPath: URL,
        source: String,
        transcriber: any TranscriptionEngine,
        label: String,
        audioSource: AudioSourceType,
        config: Config
    ) async throws -> StreamResult {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioPath.path)[.size] as? Int) ?? 0
        if fileSize <= wavHeaderSize {
            Logger.transcription.info("Skipping empty \(label, privacy: .public) audio (\(fileSize) bytes)")
            return StreamResult(segments: [], speakerDatabase: [:])
        }

        Logger.transcription.info("Transcribing \(label, privacy: .public) audio: \(audioPath.lastPathComponent, privacy: .private) (\(fileSize) bytes)")

        let segments = try await transcriber.transcribe(audioPath: audioPath, language: nil, audioSource: audioSource)

        // Capture detected language from engine output
        if let lang = segments.lazy.compactMap(\.language).first {
            detectedLanguages.append(lang)
        }

        var labeled: [LabeledSegment]
        var speakerDatabase: [String: [Float]] = [:]
        if let diarizer = diarizer {
            // Run VAD concurrently with diarization (both read the same audio file)
            async let diarizedResult = diarizer.diarize(audioPath: audioPath, numSpeakers: nil)
            async let speechMapResult = vadSpeechMap.analyze(audioPath: audioPath)

            let diarizationResult = try await diarizedResult
            let diarizedSegments = diarizationResult.segments
            // analyze() returns [SpeechRegion]? — flatten the try? double-optional
            let speechMap: [SpeechRegion]? = (try? await speechMapResult) ?? nil

            labeled = SpeakerAssignment.assign(
                transcriptSegments: segments,
                diarizationSegments: diarizedSegments,
                speechMap: speechMap,
                vadSpeechThreshold: config.vadSpeechThreshold ?? 0.5
            )
            // Remap DB keys from raw IDs ("S2") to friendly names ("Speaker 1")
            let dbKeyMap = SpeakerAssignment.buildSpeakerMap(from: diarizedSegments)
            speakerDatabase = SpeakerAssignment.remapDatabaseKeys(
                diarizationResult.speakerDatabase, using: dbKeyMap
            )
        } else {
            labeled = segments.map { seg in
                LabeledSegment(
                    start: seg.start,
                    end: seg.end,
                    speaker: "Speaker 1",
                    text: seg.text.trimmingCharacters(in: .whitespaces),
                    source: "",
                    confidence: seg.confidence,
                    language: seg.language
                )
            }
        }

        for i in labeled.indices {
            labeled[i].source = source
        }

        Logger.transcription.info("\(label.capitalized, privacy: .public) transcription: \(labeled.count) segments")
        return StreamResult(segments: labeled, speakerDatabase: speakerDatabase)
    }
}
