import Foundation
import os
import WhisperKit

public actor WhisperKitTranscriber {
    private var whisperKit: WhisperKit?
    private let modelPath: URL
    private let modelVariant: String
    private let unloadTimeout: TimeInterval
    private var unloadTask: Task<Void, Never>?

    public init(modelPath: URL, model: String = "large-v3-turbo", unloadTimeoutMinutes: Int = 60) {
        self.modelPath = modelPath.appendingPathComponent(model)
        self.modelVariant = model
        self.unloadTimeout = TimeInterval(unloadTimeoutMinutes * 60)
    }

    public func transcribe(audioPath: URL, language: String? = nil) async throws -> [TranscriptSegment] {
        let kit = try await ensureLoaded()
        cancelUnloadTimer()

        let startTime = ContinuousClock.now

        Logger.transcription.info("Transcribing: \(audioPath.lastPathComponent, privacy: .public) with model \(self.modelVariant, privacy: .public)")

        let options = DecodingOptions(
            language: language,
            wordTimestamps: true,
            compressionRatioThreshold: 1.8,
            noSpeechThreshold: 0.8
        )

        let results: [TranscriptionResult] = try await kit.transcribe(
            audioPath: audioPath.path,
            decodeOptions: options
        )

        let elapsed = ContinuousClock.now - startTime
        let seconds = elapsed.components.seconds

        var segments: [TranscriptSegment] = []
        for result in results {
            for segment in result.segments {
                segments.append(TranscriptSegment(
                    start: Double(segment.start),
                    end: Double(segment.end),
                    text: segment.text,
                    language: result.language
                ))
            }
        }

        Logger.transcription.info("Transcription complete: \(segments.count) segments in \(seconds)s — language: \(results.first?.language ?? "unknown", privacy: .public)")

        scheduleUnload()
        return SpeakerAssignment.deduplicate(segments)
    }

    private func ensureLoaded() async throws -> WhisperKit {
        if let kit = whisperKit {
            Logger.transcription.debug("WhisperKit already loaded")
            return kit
        }

        let loadStart = ContinuousClock.now
        Logger.transcription.info("Loading WhisperKit model: \(self.modelVariant, privacy: .public) from \(self.modelPath.path, privacy: .private)")

        let kit = try await WhisperKit(
            modelFolder: modelPath.path,
            verbose: false,
            prewarm: true
        )

        let loadElapsed = ContinuousClock.now - loadStart
        Logger.transcription.info("WhisperKit model loaded in \(loadElapsed.components.seconds)s")

        whisperKit = kit
        return kit
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self, unloadTimeout] in
            try? await Task.sleep(for: .seconds(unloadTimeout))
            guard !Task.isCancelled else { return }
            await self?.unloadModel()
        }
    }

    private func cancelUnloadTimer() {
        unloadTask?.cancel()
        unloadTask = nil
    }

    private func unloadModel() {
        whisperKit = nil
        Logger.transcription.info("WhisperKit model unloaded after idle timeout")
    }
}
