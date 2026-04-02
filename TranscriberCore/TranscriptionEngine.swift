import Foundation

/// Protocol for swappable transcription engines.
/// Implementations: FluidAudioEngine, WhisperCppEngine, SpeechAnalyzerEngine
public protocol TranscriptionEngine: Sendable {
    /// Human-readable engine name for logging and UI.
    var name: String { get }

    /// Transcribe an audio file, returning segments with timestamps and text.
    /// - Parameters:
    ///   - audioPath: URL to WAV/FLAC/MP3 audio file
    ///   - language: ISO language code (e.g. "en", "pt"). nil = auto-detect.
    /// - Returns: Array of transcript segments, chronologically ordered.
    func transcribe(audioPath: URL, language: String?) async throws -> [TranscriptSegment]

    /// Whether this engine is ready to transcribe (model downloaded, etc.)
    func isReady() -> Bool

    /// Prepare the engine (download models, compile CoreML, etc.)
    /// Call during setup, not during transcription timing.
    func prepare() async throws
}
