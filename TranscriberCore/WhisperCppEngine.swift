import AVFoundation
import Foundation
import os
import WhisperCppKit

/// Transcription engine backed by whisper.cpp (GGML format, Metal GPU).
/// Uses the Whisper large-v3-turbo model in GGML format.
/// Mid-range speed (~41s for 17min audio). Had language detection issues with Portuguese in benchmarks.
public actor WhisperCppEngine: TranscriptionEngine {
    private var context: WhisperContext?
    private let modelPath: URL
    private let unloadTimeout: TimeInterval
    private var unloadTask: Task<Void, Never>?

    public nonisolated let name = "WhisperCpp"

    /// - Parameters:
    ///   - modelPath: Path to the GGML model file (e.g. ~/.audio-transcribe/models/ggml-large-v3-turbo.bin)
    ///   - unloadTimeoutMinutes: Minutes of idle before unloading model from memory
    public init(modelPath: URL, unloadTimeoutMinutes: Int = 60) {
        self.modelPath = modelPath
        self.unloadTimeout = TimeInterval(unloadTimeoutMinutes * 60)
    }

    public nonisolated func isReady() -> Bool {
        FileManager.default.fileExists(atPath: modelPath.path)
    }

    public func prepare() async throws {
        let _ = try await ensureLoaded()
    }

    public func transcribe(audioPath: URL, language: String? = nil, audioSource: AudioSourceType = .system) async throws -> [TranscriptSegment] {
        let ctx = try await ensureLoaded()
        cancelUnloadTimer()

        let startTime = ContinuousClock.now

        Logger.transcription.info("Transcribing: \(audioPath.lastPathComponent, privacy: .public) with whisper.cpp")

        // whisper.cpp requires 16kHz mono Float32 PCM
        let samples = try Self.loadAudio16kMono(url: audioPath)

        var options = WhisperOptions()
        options.language = language  // nil = auto-detect
        options.translateToEnglish = false

        let segments = try ctx.transcribe(pcm16k: samples, options: options)

        let elapsed = ContinuousClock.now - startTime
        let seconds = elapsed.components.seconds

        let result = segments.map { seg in
            TranscriptSegment(
                start: seg.startTime,
                end: seg.endTime,
                text: seg.text,
                language: language
            )
        }

        Logger.transcription.info("whisper.cpp complete: \(result.count) segments in \(seconds)s")

        scheduleUnload()
        return SpeakerAssignment.deduplicate(result)
    }

    // MARK: - Lifecycle

    private static let defaultDownloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!

    /// Download the GGML model file if it doesn't exist on disk.
    private func downloadModelIfNeeded() async throws {
        guard !FileManager.default.fileExists(atPath: modelPath.path) else { return }

        let dir = modelPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        Logger.transcription.info("Downloading whisper.cpp model: \(Self.defaultDownloadURL.lastPathComponent, privacy: .public) (~1.6GB)")

        let (tempURL, response) = try await URLSession.shared.download(from: Self.defaultDownloadURL)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw WhisperCppError.downloadFailed("HTTP \(code)")
        }

        try FileManager.default.moveItem(at: tempURL, to: modelPath)
        Logger.transcription.info("whisper.cpp model downloaded to: \(self.modelPath.path, privacy: .private)")
    }

    private func ensureLoaded() async throws -> WhisperContext {
        if let ctx = context {
            Logger.transcription.debug("whisper.cpp context already loaded")
            return ctx
        }

        try await downloadModelIfNeeded()

        let loadStart = ContinuousClock.now
        Logger.transcription.info("Loading whisper.cpp model: \(self.modelPath.lastPathComponent, privacy: .public)")

        let ctx = try WhisperContext(modelPath: modelPath.path)

        let loadElapsed = ContinuousClock.now - loadStart
        Logger.transcription.info("whisper.cpp model loaded in \(loadElapsed.components.seconds)s")

        context = ctx
        return ctx
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
        context = nil
        Logger.transcription.info("whisper.cpp model unloaded after idle timeout")
    }

    // MARK: - Audio Loading

    /// Load audio file as 16kHz mono Float32 samples (whisper.cpp input format).
    private static func loadAudio16kMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let originalRate = file.processingFormat.sampleRate
        let frameCount = AVAudioFrameCount(file.length)

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw WhisperCppError.audioLoadFailed("Cannot create input buffer")
        }
        try file.read(into: inputBuffer)

        let duration = Double(file.length) / originalRate
        let targetRate: Double = 16000

        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
            throw WhisperCppError.audioLoadFailed("Cannot create sample rate converter")
        }

        let outputFrameCount = AVAudioFrameCount(ceil(duration * targetRate))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            throw WhisperCppError.audioLoadFailed("Cannot create output buffer")
        }

        var error: NSError?
        var inputProvided = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputProvided {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputProvided = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if let error { throw error }

        let floatPtr = outputBuffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: floatPtr, count: Int(outputBuffer.frameLength)))
    }

    public enum WhisperCppError: LocalizedError {
        case audioLoadFailed(String)
        case downloadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .audioLoadFailed(let msg): return "whisper.cpp audio load failed: \(msg)"
            case .downloadFailed(let msg): return "whisper.cpp model download failed: \(msg)"
            }
        }
    }
}
