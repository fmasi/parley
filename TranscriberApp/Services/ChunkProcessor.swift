import Foundation
import os
import TranscriberCore

/// Processes finalized chunks in the background: transcribe both streams,
/// diarize, VAD, speaker assignment, archive to AAC, and persist to session.json.
final class ChunkProcessor {
    private let config: Config
    private let outputDirectory: URL
    private let transcriber: any TranscriptionEngine
    private let diarizer: (any DiarizationProvider)?
    private let vadSpeechMap = VadSpeechMap()
    private let stateStore: StateStore
    private let wavHeaderSize = 44
    private let taskPriority: TaskPriority
    private var inFlightTasks: [Task<Void, Never>] = []

    /// Actor-isolated mutable session state — replaces NSLock.
    private actor StateStore {
        var sessionState: SessionState

        init(sessionState: SessionState) {
            self.sessionState = sessionState
        }

        func appendChunk(_ chunk: ProcessedChunk) -> SessionState {
            sessionState.chunks.append(chunk)
            return sessionState
        }

        func getSessionState() -> SessionState {
            sessionState
        }
    }

    init(
        config: Config,
        outputDirectory: URL,
        sessionState: SessionState,
        transcriber: any TranscriptionEngine,
        diarizer: (any DiarizationProvider)?
    ) {
        self.config = config
        self.outputDirectory = outputDirectory
        self.stateStore = StateStore(sessionState: sessionState)
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.taskPriority = switch config.resolvedQos {
        case .userInteractive: .high
        case .userInitiated: .medium
        case .background: .background
        default: .utility
        }
    }

    /// Process a finalized chunk in the background (non-blocking).
    func processChunk(_ chunk: ChunkRotator.FinalizedChunk) {
        let priority = taskPriority
        let task = Task(priority: priority) {
            await self.processChunkAsync(chunk)
        }
        inFlightTasks.append(task)
    }

    /// Process the final chunk synchronously (called at end-of-recording).
    func processLastChunk(_ chunk: ChunkRotator.FinalizedChunk) async {
        await processChunkAsync(chunk)
    }

    /// Wait for all background chunk processing to complete before merging.
    func awaitAllProcessed() async {
        for task in inFlightTasks {
            await task.value
        }
        inFlightTasks.removeAll()
    }

    /// Actor-isolated access to current session state.
    func getSessionState() async -> SessionState {
        await stateStore.getSessionState()
    }

    // MARK: - Private

    private func processChunkAsync(_ chunk: ChunkRotator.FinalizedChunk) async {
        let startTime = ContinuousClock.now
        Logger.transcription.info(
            "Chunk \(chunk.index, privacy: .public) processing started (qos: \(self.config.chunkProcessingQos, privacy: .public))"
        )

        // 1. Transcribe + diarize system audio
        let systemURL = URL(fileURLWithPath: chunk.systemPath)
        let systemResult = await transcribeStream(
            audioPath: systemURL, source: "remote", audioSource: .system, label: "chunk-\(chunk.index)-system"
        )

        // 2. Transcribe mic audio (skip if file missing or empty)
        let micURL = URL(fileURLWithPath: chunk.micPath)
        let micResult: StreamResult
        if FileManager.default.fileExists(atPath: chunk.micPath) {
            micResult = await transcribeStream(
                audioPath: micURL, source: "local", audioSource: .microphone, label: "chunk-\(chunk.index)-mic"
            )
        } else {
            micResult = StreamResult(segments: [], speakerDatabase: [:])
        }

        // 3. Merge segments
        var allSegments = systemResult.segments + micResult.segments
        let hasDualStream = !micResult.segments.isEmpty
        if hasDualStream && !allSegments.isEmpty {
            SpeakerAssignment.tagWithSourcePrefix(&allSegments)
        }
        allSegments.sort { $0.start < $1.start }

        // 3b. Remove echo segments (mic bleed of remote speaker)
        var echoRemoved = 0
        if hasDualStream {
            let dedupResult = EchoDeduplicator.deduplicate(
                segments: allSegments,
                localSpeakerDatabase: micResult.speakerDatabase,
                remoteSpeakerDatabase: systemResult.speakerDatabase,
                temporalThreshold: config.echoTemporalThreshold,
                textThreshold: config.echoTextThreshold,
                embeddingThreshold: config.echoEmbeddingThreshold
            )
            allSegments = dedupResult.segments
            echoRemoved = dedupResult.removedCount
        }

        // 4. Convert to ProcessedChunk.Segment
        let chunkSegments = allSegments.map { seg in
            ProcessedChunk.Segment(
                start: seg.start,
                end: seg.end,
                text: seg.text,
                speaker: seg.speaker,
                source: seg.source,
                qualityScore: seg.confidence
            )
        }

        // 5. Speaker databases from both streams (used for cross-chunk reconciliation, #64)
        let speakerDatabase = systemResult.speakerDatabase
        // Local stream: only present when diarization ran on the mic stream.
        let localSpeakerDatabase = hasDualStream ? micResult.speakerDatabase : [:]

        // 6. Archive WAV → AAC (store filename only for session.json portability)
        var audioPath = systemURL.lastPathComponent
        if hasDualStream {
            do {
                let archiveResult = try await AudioArchiver.archive(
                    systemAudio: systemURL,
                    micAudio: micURL,
                    outputDirectory: outputDirectory,
                    bitrateKbps: config.archiveBitrateKbps
                )
                audioPath = archiveResult.archivePath.lastPathComponent
                Logger.files.info("Chunk \(chunk.index, privacy: .public) archived: \(archiveResult.archivePath.lastPathComponent, privacy: .public)")

                // Enforce storage quota
                try StorageManager.enforceQuota(
                    in: outputDirectory,
                    limitHours: config.audioArchiveLimitHours,
                    bitrateKbps: config.archiveBitrateKbps,
                    protectedFile: archiveResult.archivePath
                )
            } catch {
                Logger.files.error("Chunk \(chunk.index, privacy: .public) archival failed, keeping WAVs: \(error, privacy: .public)")
            }
        }

        // 7. Create ProcessedChunk
        let processed = ProcessedChunk(
            index: chunk.index,
            startTime: chunk.startTime,
            audioPath: audioPath,
            segments: chunkSegments,
            speakerDatabase: speakerDatabase,
            localSpeakerDatabase: localSpeakerDatabase,
            echoSegmentsRemoved: echoRemoved
        )

        // 8. Actor-isolated append + persist
        let snapshot = await stateStore.appendChunk(processed)

        do {
            try SessionState.write(snapshot, directory: outputDirectory)
        } catch {
            Logger.state.error("Failed to write session.json for chunk \(chunk.index, privacy: .public): \(error, privacy: .public)")
        }

        let elapsed = ContinuousClock.now - startTime
        Logger.transcription.info(
            "Chunk \(chunk.index, privacy: .public) processing complete — \(elapsed.components.seconds, privacy: .public)s, \(chunkSegments.count, privacy: .public) segments"
        )
    }

    /// Result from transcribing a single stream, including speaker database if diarized.
    private struct StreamResult {
        let segments: [LabeledSegment]
        let speakerDatabase: [String: [Float]]
    }

    /// Transcribe a single audio stream, with optional diarization + VAD.
    private func transcribeStream(
        audioPath: URL,
        source: String,
        audioSource: AudioSourceType,
        label: String
    ) async -> StreamResult {
        // Recover crash-orphaned WAVs: a writer killed before finalize() leaves a
        // header that underreports the payload, so the file reads as empty/short.
        // Rebuild the size fields from the real length before reading the audio.
        WavFileWriter.repairHeader(path: audioPath.path)

        // Skip empty files (WAV header only)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioPath.path)[.size] as? Int) ?? 0
        if fileSize <= wavHeaderSize {
            Logger.transcription.info("Skipping empty \(label, privacy: .public) audio (\(fileSize) bytes)")
            return StreamResult(segments: [], speakerDatabase: [:])
        }

        Logger.transcription.info("Transcribing \(label, privacy: .public): \(audioPath.lastPathComponent, privacy: .public) (\(fileSize) bytes)")

        let segments: [TranscriptSegment]
        do {
            segments = try await transcriber.transcribe(audioPath: audioPath, language: nil, audioSource: audioSource)
        } catch {
            Logger.transcription.error("Transcription failed for \(label, privacy: .public): \(error, privacy: .public)")
            return StreamResult(segments: [], speakerDatabase: [:])
        }

        var labeled: [LabeledSegment]
        var speakerDatabase: [String: [Float]] = [:]
        if let diarizer {
            do {
                // Run diarization + VAD concurrently
                async let diarizedResult = diarizer.diarize(audioPath: audioPath, numSpeakers: nil)
                async let speechMapResult = vadSpeechMap.analyze(audioPath: audioPath)

                let diarizationResult = try await diarizedResult
                let speechMap: [SpeechRegion]? = (try? await speechMapResult) ?? nil

                labeled = SpeakerAssignment.assign(
                    transcriptSegments: segments,
                    diarizationSegments: diarizationResult.segments,
                    speechMap: speechMap,
                    vadSpeechThreshold: config.vadSpeechThreshold ?? 0.5
                )
                // Remap DB keys from raw IDs ("S2") to friendly names ("Speaker 1")
                // so they match the speaker labels in segments (used by echo dedup)
                let dbKeyMap = SpeakerAssignment.buildSpeakerMap(from: diarizationResult.segments)
                speakerDatabase = SpeakerAssignment.remapDatabaseKeys(
                    diarizationResult.speakerDatabase, using: dbKeyMap
                )
            } catch {
                Logger.transcription.error("Diarization failed for \(label, privacy: .public): \(error, privacy: .public)")
                labeled = segments.map { seg in
                    LabeledSegment(
                        start: seg.start, end: seg.end, speaker: "Speaker 1",
                        text: seg.text.trimmingCharacters(in: .whitespaces),
                        source: "", confidence: seg.confidence, language: seg.language
                    )
                }
            }
        } else {
            labeled = segments.map { seg in
                LabeledSegment(
                    start: seg.start, end: seg.end, speaker: "Speaker 1",
                    text: seg.text.trimmingCharacters(in: .whitespaces),
                    source: "", confidence: seg.confidence, language: seg.language
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
