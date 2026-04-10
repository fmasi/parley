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
        legacyDedup: Bool = false
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
        var allSegments: [LabeledSegment] = []
        var audioPaths: [URL] = []
        var localSpeakerDb: [String: [Float]] = [:]
        var remoteSpeakerDb: [String: [Float]] = [:]

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
            remoteSpeakerDb.merge(systemResult.speakerDatabase) { _, new in new }
            audioPaths.append(segmentPair.system)

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
                    localSpeakerDb.merge(micResult.speakerDatabase) { _, new in new }
                    audioPaths.append(micPath)
                }
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
                embeddingThreshold: config.echoEmbeddingThreshold,
                legacyMode: legacyDedup
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
            echoSegmentsRemoved: echoRemoved
        )

        let baseName = systemAudio.deletingPathExtension().lastPathComponent
        let jsonPath = outputDirectory.appendingPathComponent(baseName + ".json")
        try TranscriptAssembler.write(json, to: jsonPath)

        do {
            try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)
        } catch {
            Logger.files.error("Failed to write format file: \(error, privacy: .public)")
        }

        // Archive WAVs to stereo AAC (L=mic, R=system)
        if isDualStream, let micAudio {
            do {
                let archiveResult = try await AudioArchiver.archive(
                    systemAudio: systemAudio,
                    micAudio: micAudio,
                    outputDirectory: outputDirectory,
                    bitrateKbps: config.archiveBitrateKbps
                )
                // Update transcript JSON with new audio path
                Self.updateAudioPaths(in: jsonPath, to: [archiveResult.archivePath])
                Logger.files.info("Archived to: \(archiveResult.archivePath.lastPathComponent, privacy: .public)")

                // Enforce storage quota
                try StorageManager.enforceQuota(
                    in: outputDirectory,
                    limitHours: config.audioArchiveLimitHours,
                    bitrateKbps: config.archiveBitrateKbps,
                    protectedFile: archiveResult.archivePath
                )
            } catch {
                Logger.files.error("Archival failed, keeping WAV files: \(error, privacy: .public)")
            }
        }

        let elapsed = ContinuousClock.now - startTime
        Logger.transcription.info("Transcription pipeline complete — \(elapsed.components.seconds)s, output: \(jsonPath.lastPathComponent, privacy: .public)")

        return TranscriptionResult(jsonPath: jsonPath)
    }

    /// Finalize a chunked recording session: reconcile speakers, merge chunks, write transcript.
    func finalize(
        sessionState: SessionState,
        outputDirectory: URL,
        config: Config
    ) async throws -> TranscriptionResult {
        let startTime = ContinuousClock.now

        // 1. Speaker reconciliation
        Logger.transcription.info("Reconciling speakers across \(sessionState.chunks.count) chunks (cosine threshold: 0.65)")
        let speakerMapping = SpeakerReconciler.reconcile(
            chunks: sessionState.chunks,
            threshold: 0.65
        )

        // 2. Merge chunks
        let mergeResult = TranscriptMerger.merge(
            chunks: sessionState.chunks,
            speakerMapping: speakerMapping,
            meetingStart: sessionState.meetingStart
        )

        // 3. Convert MergedSegments to LabeledSegments for existing assembler
        var allSegments: [LabeledSegment] = []
        for chunk in sessionState.chunks {
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

        // 5. Audio paths from chunks
        let chunkAudioPaths = sessionState.chunks.map {
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
                    "Concatenated \(chunkAudioPaths.count, privacy: .public) chunks → \(concatResult.outputPath.lastPathComponent, privacy: .public) (passthrough: \(concatResult.usedPassthrough, privacy: .public))"
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
            echoSegmentsRemoved: totalEchoRemoved
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
        Logger.transcription.info("Chunked pipeline finalized — \(elapsed.components.seconds)s, \(mergeResult.chunkCount) chunks, output: \(jsonPath.lastPathComponent, privacy: .public)")

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

    /// Update the audio_paths in a transcript JSON file after archival.
    private static func updateAudioPaths(in jsonPath: URL, to newPaths: [URL]) {
        guard let data = try? Data(contentsOf: jsonPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var metadata = json["metadata"] as? [String: Any]
        else { return }

        metadata["audio_paths"] = newPaths.map { $0.path }
        metadata["audio_files"] = newPaths.map { $0.lastPathComponent }
        json["metadata"] = metadata

        if let updatedData = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? updatedData.write(to: jsonPath, options: .atomic)
            Logger.files.info("Updated audio_paths in \(jsonPath.lastPathComponent, privacy: .public)")
        }
    }

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

        Logger.transcription.info("Transcribing \(label, privacy: .public) audio: \(audioPath.lastPathComponent, privacy: .public) (\(fileSize) bytes)")

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
