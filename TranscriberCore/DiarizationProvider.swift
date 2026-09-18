import Foundation

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
