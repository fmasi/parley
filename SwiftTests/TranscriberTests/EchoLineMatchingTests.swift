import Testing
import Foundation
@testable import TranscriberCore

/// The per-line echo decision (#363, #365). Synthetic lines only, nothing from a recording.
struct EchoLineMatchingTests {

    private func remote(_ start: Double, _ end: Double, _ text: String) -> LabeledSegment {
        LabeledSegment(start: start, end: end, speaker: "Remote Speaker 1", text: text, source: "remote")
    }

    private func local(_ start: Double, _ end: Double, _ text: String) -> LabeledSegment {
        LabeledSegment(start: start, end: end, speaker: "Local Speaker 1", text: text, source: "local")
    }

    private func flagged(_ result: EchoDeduplicator.DeduplicationResult) -> [String] {
        result.segments.filter(\.echo).map(\.text)
    }

    // MARK: - #363: numbers written two ways

    /// The loudspeaker call behind #363: the mic's recogniser spelled the numbers out, the system's wrote
    /// digits. Word overlap was 40-67 %, so these echo lines were not flagged.
    @Test func anEchoWhoseNumbersTheTwoSidesWroteDifferentlyIsFlagged() {
        let segments = [
            remote(10, 13, "The price is 195 per seat."),
            local(10.2, 13.2, "The price is one ninety five per seat."),
            remote(20, 24, "In 2026 we had 183 of them."),
            local(20.2, 24.2, "In twenty twenty six we had one eighty three of them."),
            remote(30, 33, "We budgeted 7,500 for it."),
            local(30.2, 33.2, "We budgeted seven thousand five hundred for it."),
        ]
        let result = EchoDeduplicator.deduplicate(segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:])
        #expect(result.flaggedCount == 3)
        #expect(result.segments.filter { $0.source == "local" }.allSatisfy { $0.echo })
    }

    /// A short line whose number differs does not match: the number is one word, whatever its spelling.
    /// (Its unnormalised words matched no better: "one eighty five" against "195" shares nothing.)
    @Test func aLineWithADifferentNumberIsNotFlagged() {
        let segments = [
            remote(10, 12, "It was 195."),
            local(10.2, 12.2, "It was one eighty five."),
            remote(20, 23, "We budgeted 7,500."),
            local(20.2, 23.2, "We budgeted seven thousand six hundred."),
        ]
        let result = EchoDeduplicator.deduplicate(segments: segments, localSpeakerDatabase: [:], remoteSpeakerDatabase: [:])
        #expect(result.flaggedCount == 0)
    }
}
