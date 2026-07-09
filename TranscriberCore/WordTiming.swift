import Foundation

/// Timing for one ASR unit inside a segment — a FluidAudio token (sub-word) or a
/// SpeechAnalyzer run. Engine-neutral (no SDK types) so both engines can populate it and the
/// shared assignment layer can re-split segments at true speaker-change boundaries (issue #120).
/// `text` is expected to carry the unit's own leading spacing verbatim, so a piece's text
/// reconstructs by plain concatenation + trim — confirmed true for FluidAudio tokens (verified in
/// `groupTokensAttachesWordTimings`); NOT independently verifiable for SpeechAnalyzer's runs, whose
/// space-ownership is an Apple-internal detail — `SpeechAnalyzerEngine` explicitly round-trip-checks
/// this per segment before ever populating `words`, and disables splitting (falls to `nil`) if the
/// assumption doesn't hold for that segment.
public struct WordTiming: Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}
