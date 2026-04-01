import Foundation
import os
import TranscriberCore

struct TranscriptionResult {
    let jsonPath: URL
}

final class TranscriptionRunner {
    enum RunnerError: LocalizedError {
        case modelNotDownloaded(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotDownloaded(let model):
                return "Whisper model '\(model)' is not downloaded. Open Settings to download it."
            case .failed(let msg):
                return msg
            }
        }
    }

    private var transcriber: (any TranscriptionEngine)?
    private var lastModelKey: String?
    private var diarizer: (any DiarizationProvider)?

    /// Minimum WAV file size to consider non-empty (44 bytes = WAV header only).
    private let wavHeaderSize = 44

    func run(
        systemAudio: URL,
        micAudio: URL?,
        outputDirectory: URL,
        config: Config
    ) async throws -> TranscriptionResult {
        let startTime = ContinuousClock.now

        // 1. Resolve model path and verify the model exists on disk
        let storagePath = ModelManager.resolveStoragePath(config.modelStoragePath)
        let modelDir = storagePath.appendingPathComponent(config.whisperModel)

        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            Logger.transcription.error("Model not found at \(modelDir.path, privacy: .private)")
            throw RunnerError.modelNotDownloaded(config.whisperModel)
        }

        // 2. Lazy-init transcriber, reuse if same model for caching benefit
        let modelKey = "\(storagePath.path)/\(config.whisperModel)"
        if transcriber == nil || lastModelKey != modelKey {
            Logger.transcription.info("Creating WhisperKitTranscriber — model: \(config.whisperModel, privacy: .public)")
            transcriber = WhisperKitTranscriber(
                modelPath: storagePath,
                model: config.whisperModel,
                unloadTimeoutMinutes: config.modelUnloadTimeout
            )
            lastModelKey = modelKey
        }

        guard let transcriber = transcriber else {
            throw RunnerError.failed("Failed to initialize transcriber")
        }

        let isDualStream = micAudio != nil
        var allSegments: [LabeledSegment] = []

        // 3. Transcribe system audio (remote)
        let systemSegments = try await transcribeStream(
            audioPath: systemAudio,
            source: "remote",
            transcriber: transcriber,
            label: "system"
        )
        allSegments.append(contentsOf: systemSegments)

        // 4. Transcribe mic audio (local) if present
        if let micPath = micAudio {
            let micSegments = try await transcribeStream(
                audioPath: micPath,
                source: "local",
                transcriber: transcriber,
                label: "mic"
            )
            allSegments.append(contentsOf: micSegments)
        }

        // 5. If dual-stream, tag speakers with source prefix
        if isDualStream && !allSegments.isEmpty {
            SpeakerAssignment.tagWithSourcePrefix(&allSegments)
            Logger.transcription.debug("Applied source prefix tags for dual-stream")
        }

        // 6. Sort all segments chronologically
        allSegments.sort { $0.start < $1.start }
        Logger.transcription.info("Total segments after merge: \(allSegments.count)")

        // 7. Build audio paths list for metadata
        var audioPaths = [systemAudio]
        if let mic = micAudio {
            audioPaths.append(mic)
        }

        let detectedLanguage = allSegments.first.flatMap { _ in
            // Language was detected during transcription; not stored on LabeledSegment.
            // Use a sensible default.
            nil as String?
        } ?? "en"

        let hasDiarization = diarizer != nil
        let json = TranscriptAssembler.assemble(
            segments: allSegments,
            audioPaths: audioPaths,
            outputFormat: config.outputFormat,
            language: detectedLanguage,
            numSpeakers: nil,
            diarization: hasDiarization,
            dualStream: isDualStream
        )

        // 8. Write JSON output
        let baseName = systemAudio.deletingPathExtension().lastPathComponent
        let jsonPath = outputDirectory.appendingPathComponent(baseName + ".json")

        try TranscriptAssembler.write(json, to: jsonPath)

        // Generate format file (SRT/TXT) if output_format != json
        do {
            try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)
        } catch {
            Logger.files.error("Failed to write format file: \(error, privacy: .public)")
        }

        let elapsed = ContinuousClock.now - startTime
        Logger.transcription.info("Transcription pipeline complete — \(elapsed.components.seconds)s, output: \(jsonPath.lastPathComponent, privacy: .public)")

        return TranscriptionResult(jsonPath: jsonPath)
    }

    func setTranscriber(_ engine: any TranscriptionEngine) {
        self.transcriber = engine
        self.lastModelKey = engine.name
        Logger.transcription.info("Transcription engine set: \(engine.name, privacy: .public)")
    }

    func setDiarizer(_ provider: any DiarizationProvider) {
        self.diarizer = provider
        Logger.transcription.info("Diarization provider set: \(String(describing: type(of: provider)), privacy: .public)")
    }

    // MARK: - Private

    private func transcribeStream(
        audioPath: URL,
        source: String,
        transcriber: any TranscriptionEngine,
        label: String
    ) async throws -> [LabeledSegment] {
        // Skip empty files (WAV header only = 44 bytes)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioPath.path)[.size] as? Int) ?? 0
        if fileSize <= wavHeaderSize {
            Logger.transcription.info("Skipping empty \(label, privacy: .public) audio (\(fileSize) bytes)")
            return []
        }

        Logger.transcription.info("Transcribing \(label, privacy: .public) audio: \(audioPath.lastPathComponent, privacy: .public) (\(fileSize) bytes)")

        // Transcribe (deduplicate is called internally by WhisperKitTranscriber)
        let segments = try await transcriber.transcribe(audioPath: audioPath, language: nil)

        // Diarize if provider is available
        var labeled: [LabeledSegment]
        if let diarizer = diarizer {
            Logger.transcription.info("Running diarization on \(label, privacy: .public) audio")
            let diarizedSegments = try await diarizer.diarize(audioPath: audioPath, numSpeakers: nil)
            labeled = SpeakerAssignment.assign(
                transcriptSegments: segments,
                diarizationSegments: diarizedSegments
            )
        } else {
            // No diarization -- convert TranscriptSegments to LabeledSegments with "Speaker 1"
            labeled = segments.map { seg in
                LabeledSegment(
                    start: seg.start,
                    end: seg.end,
                    speaker: "Speaker 1",
                    text: seg.text.trimmingCharacters(in: CharacterSet.whitespaces),
                    source: ""
                )
            }
        }

        // Tag source for dual-stream merging
        for i in labeled.indices {
            labeled[i].source = source
        }

        Logger.transcription.info("\(label.capitalized, privacy: .public) transcription: \(labeled.count) segments")
        return labeled
    }
}
