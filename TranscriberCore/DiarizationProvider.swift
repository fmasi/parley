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

/// The half of a diarization that does not depend on the speaker count (#341): segmentation and the
/// speaker embeddings, with the audio they came from. Clustering it at a count is the other half,
/// and is cheap next to it.
///
/// Opaque: only the provider that made it can cluster it (FluidAudio's `PreparedDiarization` inside).
/// It holds the channel's whole decoded audio (16 kHz mono Float, about 230 MB an hour) — the
/// clustering re-reads short spans of it — plus the embeddings and the segmentation scores.
public struct PreparedSpeakerAnalysis: Sendable {
    /// The provider's own prepared value.
    let payload: any Sendable
    /// The samples it was made from, for the log and the memory note: 16 kHz mono.
    public let sampleCount: Int
    /// The speaker embeddings it holds.
    public let embeddingCount: Int

    public init(payload: any Sendable, sampleCount: Int, embeddingCount: Int) {
        self.payload = payload
        self.sampleCount = sampleCount
        self.embeddingCount = embeddingCount
    }
}

/// A diarizer that can keep the count-independent half of its work (#341): `prepare` once, then
/// `cluster` at each count. `cluster(prepare(audio))` at a count must give what
/// `diarize(audio:numSpeakers:)` gives at that count — the AMI golden test pins it for FluidAudio.
public protocol SpeakerAnalysisReusing: DiarizationProvider {
    /// Everything that shapes `prepare`'s result on this provider: the models, where they run, and the
    /// segmentation and embedding settings. Not the clustering settings, which `prepare` never reads.
    /// Part of the cache key, so an analysis made under other settings is never clustered.
    var preparationIdentity: String { get }

    /// Segment `audio` (16 kHz mono) and extract its speaker embeddings.
    /// - Parameter speakerCountHint: the count the first `cluster` will ask for, so the work runs on
    ///   the model stack that clustering loads anyway; the result does not depend on it.
    /// - Parameter progress: `(chunksProcessed, totalChunks)`, from the provider's own threads.
    func prepare(
        audio: [Float],
        speakerCountHint: Int?,
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> PreparedSpeakerAnalysis

    /// Cluster a prepared analysis at `numSpeakers`, as `diarize(audio:numSpeakers:progress:)` would.
    func cluster(_ prepared: PreparedSpeakerAnalysis, numSpeakers: Int?) async throws -> DiarizationResult
}

/// A prepared analysis handed to a provider that did not make it.
public struct ForeignSpeakerAnalysis: Error {}
