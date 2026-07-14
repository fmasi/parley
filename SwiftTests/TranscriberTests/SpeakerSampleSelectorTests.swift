import Foundation
import Testing
@testable import TranscriberCore

@Suite struct SpeakerSampleSelectorTests {

    private func seg(_ speaker: String, _ start: Double, _ end: Double, _ text: String = "hi")
        -> SpeakerSampleSelector.Candidate {
        .init(speaker: speaker, start: start, end: end, source: "remote", text: text)
    }

    /// The core regression: the LONGEST segment is crosstalk, a shorter one is clean.
    /// Ranking by duration alone hands the user 40s of two people talking at once.
    @Test func prefersCleanSampleOverLongerOverlappedOne() {
        let all = [
            seg("Yumi", 100, 140, "long but talked over"),   // 40s, overlapped
            seg("Fred", 110, 130),                            // overlaps Yumi's long one
            seg("Yumi", 200, 225, "clean solo"),              // 25s, clean
        ]
        let ranked = SpeakerSampleSelector.rank(speaker: "Yumi", allSegments: all)
        #expect(ranked.first?.text == "clean solo")
        // The overlapped one is kept as a fallback, not discarded.
        #expect(ranked.count == 2)
        #expect(ranked.last?.text == "long but talked over")
    }

    @Test func ranksCleanSamplesByDurationDescending() {
        let all = [
            seg("Yumi", 0, 5, "short"),
            seg("Yumi", 10, 40, "longest"),
            seg("Yumi", 50, 70, "middle"),
        ]
        let ranked = SpeakerSampleSelector.rank(speaker: "Yumi", allSegments: all)
        #expect(ranked.map(\.text) == ["longest", "middle", "short"])
    }

    /// A speaker whose every segment is crosstalk must still get samples — otherwise they
    /// become unrenameable, which is worse than an imperfect sample.
    @Test func fallsBackToOverlappedWhenNothingIsClean() {
        let all = [
            seg("Yumi", 100, 120, "overlapped A"),
            seg("Yumi", 200, 215, "overlapped B"),
            seg("Fred", 100, 120),
            seg("Fred", 200, 215),
        ]
        let ranked = SpeakerSampleSelector.rank(speaker: "Yumi", allSegments: all)
        #expect(ranked.map(\.text) == ["overlapped A", "overlapped B"])
    }

    /// Boundary jitter / a breath from the next speaker must not condemn a good sample.
    @Test func toleratesSliverOverlap() {
        let all = [
            seg("Yumi", 100, 130, "essentially clean"),
            seg("Fred", 129.9, 140),   // 0.1s clip — under tolerance
        ]
        let ranked = SpeakerSampleSelector.rank(speaker: "Yumi", allSegments: all)
        #expect(ranked.first?.text == "essentially clean")
    }

    @Test func overlapBeyondToleranceDisqualifies() {
        let all = [
            seg("Yumi", 100, 130, "talked over"),
            seg("Fred", 125, 140),   // 5s overlap
            seg("Yumi", 200, 210, "clean"),
        ]
        let ranked = SpeakerSampleSelector.rank(speaker: "Yumi", allSegments: all)
        #expect(ranked.first?.text == "clean")
    }

    /// A speaker's own segments may abut or overlap (one voice split in two) — that is not
    /// contamination and must not disqualify the sample.
    @Test func sameSpeakerOverlapIsNotContamination() {
        let all = [
            seg("Yumi", 100, 130, "part one"),
            seg("Yumi", 129, 150, "part two"),
        ]
        let ranked = SpeakerSampleSelector.rank(speaker: "Yumi", allSegments: all)
        #expect(ranked.first?.text == "part one")
        #expect(ranked.count == 2)
    }

    @Test func localAndRemoteSpeakersContaminateEachOther() {
        // Cross-source crosstalk is the common case: the user talking over a remote participant.
        let all = [
            SpeakerSampleSelector.Candidate(
                speaker: "Yumi", start: 100, end: 140, source: "remote", text: "talked over"
            ),
            SpeakerSampleSelector.Candidate(
                speaker: "Frederic", start: 110, end: 130, source: "local", text: "interjection"
            ),
            SpeakerSampleSelector.Candidate(
                speaker: "Yumi", start: 200, end: 220, source: "remote", text: "clean"
            ),
        ]
        let ranked = SpeakerSampleSelector.rank(speaker: "Yumi", allSegments: all)
        #expect(ranked.first?.text == "clean")
    }

    @Test func unknownSpeakerYieldsNothing() {
        #expect(SpeakerSampleSelector.rank(speaker: "Nobody", allSegments: [seg("Yumi", 0, 10)]).isEmpty)
    }

    @Test func zeroLengthSegmentsAreIgnored() {
        let all = [seg("Yumi", 100, 100, "empty"), seg("Yumi", 200, 210, "real")]
        let ranked = SpeakerSampleSelector.rank(speaker: "Yumi", allSegments: all)
        #expect(ranked.map(\.text) == ["real"])
    }
}
