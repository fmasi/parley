import Foundation

/// Hint for engines about the audio source, enabling source-specific preprocessing.
public enum AudioSourceType: Sendable {
    /// System/app audio (e.g. Zoom, Teams output)
    case system
    /// Microphone input
    case microphone
}

/// Protocol for swappable transcription engines.
/// Implementations: FluidAudioEngine, WhisperCppEngine, SpeechAnalyzerEngine
public protocol TranscriptionEngine: Sendable {
    /// Human-readable engine name for logging and UI.
    var name: String { get }

    /// Transcribe an audio file, returning segments with timestamps and text.
    /// - Parameters:
    ///   - audioPath: URL to WAV/FLAC/MP3 audio file
    ///   - language: ISO language code (e.g. "en", "pt"). nil = auto-detect.
    ///   - audioSource: Hint about the audio source for engine-specific preprocessing.
    /// - Returns: Array of transcript segments, chronologically ordered.
    func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment]

    /// Whether this engine is ready to transcribe (model downloaded, etc.)
    func isReady() -> Bool

    /// Prepare the engine (download models, compile CoreML, etc.)
    /// Call during setup, not during transcription timing.
    func prepare() async throws
}
