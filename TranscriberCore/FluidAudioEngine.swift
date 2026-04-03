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
    private lazy var textNormalizer = TextNormalizer()

    public nonisolated let name = "FluidAudio"

    public init(unloadTimeoutMinutes: Int = 60) {
        self.unloadTimeout = TimeInterval(unloadTimeoutMinutes * 60)
    }

    public nonisolated func isReady() -> Bool {
        Self.isModelCached()
    }

    public func prepare() async throws {
        let _ = try await ensureLoaded()
    }

    /// Returns true if the Parakeet model files are already present in the local cache.
    /// This is a synchronous disk check — cheap but not free.
    public static func isModelCached() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory())
    }

    /// Download the Parakeet model files to the local cache without loading them into memory.
    /// Safe to call even if models are already cached — returns immediately in that case.
    public static func preDownloadModel(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        _ = try await AsrModels.download(
            progressHandler: progress.map { handler in
                { @Sendable p in handler(p.fractionCompleted) }
            }
        )
        Logger.transcription.info("FluidAudio model pre-download complete")
    }

    public func transcribe(audioPath: URL, language: String? = nil, audioSource: AudioSourceType = .system) async throws -> [TranscriptSegment] {
        let mgr = try await ensureLoaded()
        cancelUnloadTimer()

        let startTime = ContinuousClock.now

        let fluidSource: AudioSource = audioSource == .microphone ? .microphone : .system
        Logger.transcription.info("Transcribing: \(audioPath.lastPathComponent, privacy: .public) with FluidAudio (source: \(String(describing: fluidSource), privacy: .public))")

        let result = try await mgr.transcribe(audioPath, source: fluidSource)

        let elapsed = ContinuousClock.now - startTime
        let seconds = elapsed.components.seconds
        let confidence = result.confidence

        // Group token timings into sentence-level segments by splitting on punctuation
        let timings = (result.tokenTimings ?? []).map { t in
            TokenTiming(startTime: t.startTime, endTime: t.endTime, token: t.token)
        }
        var segments = Self.groupTokensIntoSegments(timings, language: language, confidence: confidence)

        // Apply Inverse Text Normalization (spoken → written form, e.g. "two hundred" → "200")
        let normalizer = textNormalizer
        if normalizer.isNativeAvailable {
            segments = segments.map { seg in
                let normalized = normalizer.normalizeSentence(seg.text)
                if normalized != seg.text {
                    return TranscriptSegment(start: seg.start, end: seg.end, text: normalized, language: seg.language, confidence: seg.confidence)
                }
                return seg
            }
            Logger.transcription.debug("ITN applied to \(segments.count) segments")
        }

        Logger.transcription.info("FluidAudio complete: \(segments.count) segments in \(seconds)s (confidence: \(confidence))")

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
        language: String?,
        confidence: Float? = nil
    ) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var currentText = ""
        var segStart: Double = 0
        var segEnd: Double = 0

        for (i, t) in timings.enumerated() {
            if currentText.isEmpty { segStart = t.startTime }
            currentText += t.token
            segEnd = t.endTime
            let endsWithPunct = t.token.last.map { ".!?".contains($0) } ?? false
            // Don't split on "." when the next token starts with a digit (e.g. "1." + "5 million")
            let isDecimalDot: Bool = endsWithPunct && t.token.last == "." && i + 1 < timings.count
                && timings[i + 1].token.first?.isNumber == true
            let isSentenceEnd = (endsWithPunct && !isDecimalDot) || i == timings.count - 1
            if isSentenceEnd {
                let trimmed = currentText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    segments.append(TranscriptSegment(
                        start: segStart,
                        end: segEnd,
                        text: trimmed,
                        language: language,
                        confidence: confidence
                    ))
                }
                currentText = ""
            }
        }
        return segments
    }
}
