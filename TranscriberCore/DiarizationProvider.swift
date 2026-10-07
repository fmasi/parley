import Foundation
import enum FluidAudio.OfflineDiarizationError

public struct DiarizedSegment: Sendable {
    public let start: Double
    public let end: Double
    public let speaker: String
    public let qualityScore: Float?

    public init(start: Double, end: Double, speaker: String, qualityScore: Float? = nil) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.qualityScore = qualityScore
    }
}

public struct DiarizationResult: Sendable {
    public let segments: [DiarizedSegment]
    public let speakerDatabase: [String: [Float]]

    public init(segments: [DiarizedSegment], speakerDatabase: [String: [Float]] = [:]) {
        self.segments = segments
        self.speakerDatabase = speakerDatabase
    }
}

public protocol DiarizationProvider: Sendable {
    func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult

    /// Whether its model is there to diarize with — a LOOK, never a download (L review 232): a salvage with audio to
    /// recognise asks it, as Setup does, and one that is not ready keeps its session pending.
    func isReady() async -> Bool

    /// Diarize pre-decoded mono samples at the provider's target sample rate (16 kHz for
    /// FluidAudio), rather than a file path.
    ///
    /// Exists so a caller that must ALSO feed the exact same samples to another consumer (VAD,
    /// in `TranscriptRediarizer`, #204) decodes the audio once and shares the buffer, instead of
    /// handing this provider a path and letting it decode its own copy.
    /// - Parameter progress: optional `(chunksProcessed, totalChunks)` callback for long inputs.
    func diarize(
        audio: [Float],
        numSpeakers: Int?,
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> DiarizationResult
}

extension DiarizationProvider {
    public func isReady() async -> Bool { true }
}

/// What a diarizer's throw means for the stream it was diarizing.
public enum DiarizerThrow {
    /// The diarizer found too little speech to attribute the stream's words to anyone: FluidAudio's
    /// `OfflineDiarizationError.noSpeechDetected` (NSError code 5). It throws that on empty audio, and when no 10 s window
    /// has a speaker active for at least 20 % of it, so no embedding is extracted (a few words in a short chunk, #302).
    /// Not a failure: the lines stay unattributed. Every other error is a failure.
    public static func isTooLittleSpeech(_ error: any Error) -> Bool {
        if case .noSpeechDetected? = error as? OfflineDiarizationError { return true }
        return false
    }
}
