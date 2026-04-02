import Foundation
import os
import FluidAudio

/// A token with timing information, matching FluidAudio's token timing output.
public struct TokenTiming: Sendable {
    public let startTime: Double
    public let endTime: Double
    public let token: String

    public init(startTime: Double, endTime: Double, token: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.token = token
    }
}

/// Transcription engine backed by FluidAudio (Parakeet model, CoreML/ANE).
/// Fastest engine in benchmarks (~7s for 17min audio). Supports 25 EU languages.
public actor FluidAudioEngine: TranscriptionEngine {
    private var manager: AsrManager?
    private let unloadTimeout: TimeInterval
    private var unloadTask: Task<Void, Never>?

    public nonisolated let name = "FluidAudio"

    public init(unloadTimeoutMinutes: Int = 60) {
        self.unloadTimeout = TimeInterval(unloadTimeoutMinutes * 60)
    }

    public nonisolated func isReady() -> Bool {
        // FluidAudio downloads models on first use via AsrModels.downloadAndLoad().
        // We can't cheaply check if the model is cached without hitting disk,
        // so we report true and let prepare() handle any download.
        true
    }

    public func prepare() async throws {
        let _ = try await ensureLoaded()
    }

    public func transcribe(audioPath: URL, language: String? = nil) async throws -> [TranscriptSegment] {
        let mgr = try await ensureLoaded()
        cancelUnloadTimer()

        let startTime = ContinuousClock.now

        Logger.transcription.info("Transcribing: \(audioPath.lastPathComponent, privacy: .public) with FluidAudio")

        let result = try await mgr.transcribe(audioPath, source: .system)

        let elapsed = ContinuousClock.now - startTime
        let seconds = elapsed.components.seconds

        // Group token timings into sentence-level segments by splitting on punctuation
        let timings = (result.tokenTimings ?? []).map { t in
            TokenTiming(startTime: t.startTime, endTime: t.endTime, token: t.token)
        }
        let segments = Self.groupTokensIntoSegments(timings, language: language)

        Logger.transcription.info("FluidAudio complete: \(segments.count) segments in \(seconds)s")

        scheduleUnload()
        return SpeakerAssignment.deduplicate(segments)
    }

    // MARK: - Lifecycle

    private func ensureLoaded() async throws -> AsrManager {
        if let mgr = manager {
            Logger.transcription.debug("FluidAudio already loaded")
            return mgr
        }

        let loadStart = ContinuousClock.now
        Logger.transcription.info("Loading FluidAudio model (Parakeet)...")

        let models = try await AsrModels.downloadAndLoad()
        let mgr = AsrManager()
        try await mgr.initialize(models: models)

        let loadElapsed = ContinuousClock.now - loadStart
        Logger.transcription.info("FluidAudio model loaded in \(loadElapsed.components.seconds)s")

        manager = mgr
        return mgr
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
        manager = nil
        Logger.transcription.info("FluidAudio model unloaded after idle timeout")
    }
}

extension FluidAudioEngine {
    /// Group token timings into sentence-level segments by splitting on punctuation (.!?).
    /// Pure logic, no SDK dependency — testable.
    public nonisolated static func groupTokensIntoSegments(
        _ timings: [TokenTiming],
        language: String?
    ) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var currentText = ""
        var segStart: Double = 0
        var segEnd: Double = 0

        for (i, t) in timings.enumerated() {
            if currentText.isEmpty { segStart = t.startTime }
            currentText += t.token
            segEnd = t.endTime
            let isPunct = t.token.last.map { ".!?".contains($0) } ?? false
            if isPunct || i == timings.count - 1 {
                let trimmed = currentText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    segments.append(TranscriptSegment(
                        start: segStart,
                        end: segEnd,
                        text: trimmed,
                        language: language
                    ))
                }
                currentText = ""
            }
        }
        return segments
    }
}
