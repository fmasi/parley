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
    private let processingQueue: DispatchQueue
    private var sessionState: SessionState
    private let sessionLock = NSLock()
    private let wavHeaderSize = 44

    init(
        config: Config,
        outputDirectory: URL,
        sessionState: SessionState,
        transcriber: any TranscriptionEngine,
        diarizer: (any DiarizationProvider)?
    ) {
        self.config = config
        self.outputDirectory = outputDirectory
        self.sessionState = sessionState
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.processingQueue = DispatchQueue(
            label: "com.audio-transcribe.chunk-processor",
            qos: DispatchQoS(qosClass: config.resolvedQos, relativePriority: 0)
        )
    }

    /// Process a finalized chunk in the background (non-blocking).
    func processChunk(_ chunk: ChunkRotator.FinalizedChunk) {
        processingQueue.async {
            Task { await self.processChunkAsync(chunk) }
        }
    }

    /// Process the final chunk synchronously (called at end-of-recording).
    func processLastChunk(_ chunk: ChunkRotator.FinalizedChunk) async {
        await processChunkAsync(chunk)
    }

    /// Thread-safe access to current session state.
    func getSessionState() -> SessionState {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessionState
    }

    // MARK: - Private

    private func processChunkAsync(_ chunk: ChunkRotator.FinalizedChunk) async {
        let startTime = ContinuousClock.now
        Logger.transcription.info(
            "Chunk \(chunk.index, privacy: .public) processing started (qos: \(self.config.chunkProcessingQos, privacy: .public))"
        )

        // 1. Transcribe system audio
        let systemURL = URL(fileURLWithPath: chunk.systemPath)
        let systemSegments = await transcribeStream(
            audioPath: systemURL, source: "remote", audioSource: .system, label: "chunk-\(chunk.index)-system"
        )

        // 2. Transcribe mic audio (skip if file missing or empty)
        let micURL = URL(fileURLWithPath: chunk.micPath)
        let micSegments: [LabeledSegment]
        if FileManager.default.fileExists(atPath: chunk.micPath) {
            micSegments = await transcribeStream(
                audioPath: micURL, source: "local", audioSource: .microphone, label: "chunk-\(chunk.index)-mic"
            )
        } else {
            micSegments = []
        }

        // 3. Merge segments
        var allSegments = systemSegments + micSegments
        let hasDualStream = !micSegments.isEmpty
        if hasDualStream && !allSegments.isEmpty {
            SpeakerAssignment.tagWithSourcePrefix(&allSegments)
        }
        allSegments.sort { $0.start < $1.start }

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

        // 5. Extract speaker database from diarization (collected during transcribeStream)
        // The speaker database is populated per-chunk from diarization results.
        // For now, pass empty — cross-chunk reconciliation is handled by SpeakerReconciler.
        let speakerDatabase: [String: [Float]] = [:]

        // 6. Archive WAV → AAC
        var audioPath = systemURL.path
        if hasDualStream {
            do {
                let archiveResult = try await AudioArchiver.archive(
                    systemAudio: systemURL,
                    micAudio: micURL,
                    outputDirectory: outputDirectory,
                    bitrateKbps: config.archiveBitrateKbps
                )
                audioPath = archiveResult.archivePath.path
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
            speakerDatabase: speakerDatabase
        )

        // 8. Thread-safe append + persist
        let snapshot = appendChunk(processed)

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

    /// Thread-safe: append a chunk and return the updated session state snapshot.
    private func appendChunk(_ chunk: ProcessedChunk) -> SessionState {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        sessionState.chunks.append(chunk)
        return sessionState
    }

    /// Transcribe a single audio stream, with optional diarization + VAD.
    private func transcribeStream(
        audioPath: URL,
        source: String,
        audioSource: AudioSourceType,
        label: String
    ) async -> [LabeledSegment] {
        // Skip empty files (WAV header only)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioPath.path)[.size] as? Int) ?? 0
        if fileSize <= wavHeaderSize {
            Logger.transcription.info("Skipping empty \(label, privacy: .public) audio (\(fileSize) bytes)")
            return []
        }

        Logger.transcription.info("Transcribing \(label, privacy: .public): \(audioPath.lastPathComponent, privacy: .public) (\(fileSize) bytes)")

        let segments: [TranscriptSegment]
        do {
            segments = try await transcriber.transcribe(audioPath: audioPath, language: nil, audioSource: audioSource)
        } catch {
            Logger.transcription.error("Transcription failed for \(label, privacy: .public): \(error, privacy: .public)")
            return []
        }

        var labeled: [LabeledSegment]
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
            } catch {
                Logger.transcription.error("Diarization failed for \(label, privacy: .public): \(error, privacy: .public)")
                // Fall back to unlabeled segments
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
        return labeled
    }
}
