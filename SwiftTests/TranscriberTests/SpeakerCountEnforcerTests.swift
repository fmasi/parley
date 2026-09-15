import Testing
import Foundation
@testable import TranscriberCore

/// A stated speaker count has to be binding (#201).
///
/// On an 82-minute one-local/one-remote call the user set the remote channel to 1 and pressed
/// Re-detect; it came back with 2 again. Two mechanisms conspired: `maxSpeakers` is a target
/// rather than a ceiling in the clusterer, and stating a count sets `speakerCountIsUserStated`,
/// which switches minority absorption OFF — so the one thing that could have merged the spurious
/// cluster was disabled precisely when the user had said it was spurious.
///
/// This suite pins the replacement: a deterministic post-pass that merges clusters until the
/// stated count is what the transcript actually shows.
@Suite("SpeakerCountEnforcer")
struct SpeakerCountEnforcerTests {

    private func seg(_ start: Double, _ end: Double, _ speaker: String) -> DiarizedSegment {
        DiarizedSegment(start: start, end: end, speaker: speaker)
    }

    /// A 2-D embedding at a given angle, so a test can state "C sounds like B, not like A" as
    /// geometry instead of as an opaque vector: cosine similarity IS the cosine of the angle.
    private func embedding(_ degrees: Double) -> [Float] {
        let r = degrees * .pi / 180
        return [Float(Foundation.cos(r)), Float(Foundation.sin(r))]
    }

    private func speakers(_ result: DiarizationResult) -> Set<String> {
        Set(result.segments.map(\.speaker))
    }

    private func speech(_ result: DiarizationResult) -> Double {
        result.segments.reduce(0) { $0 + ($1.end - $1.start) }
    }

    @Test("three clusters forced to one leave a single label and every turn")
    func threeIntoOne() {
        let input = DiarizationResult(
            segments: [seg(0, 100, "S1"), seg(100, 150, "S2"), seg(150, 160, "S3")],
            speakerDatabase: ["S1": embedding(0), "S2": embedding(80), "S3": embedding(85)]
        )
        let out = SpeakerCountEnforcer.enforce(input, to: 1)
        #expect(speakers(out).count == 1)
        #expect(out.segments.count == 3)
        #expect(out.speakerDatabase.count == 1)
    }

    @Test("forcing three to two merges the smallest cluster into the one it sounds most like")
    func smallestMergesIntoNearest() {
        // S3 (10s) is the smallest. By angle it is 5 degrees from S2 and 85 from S1, so a
        // similarity-driven merge must fold it into S2 — not into the longest cluster, which a
        // duration-only rule would pick.
        let input = DiarizationResult(
            segments: [seg(0, 100, "S1"), seg(100, 150, "S2"), seg(150, 160, "S3")],
            speakerDatabase: ["S1": embedding(0), "S2": embedding(80), "S3": embedding(85)]
        )
        let out = SpeakerCountEnforcer.enforce(input, to: 2)
        #expect(speakers(out) == ["S1", "S2"])
        let moved = out.segments.first { $0.start == 150 }
        #expect(moved?.speaker == "S2")
        #expect(out.speakerDatabase.keys.sorted() == ["S1", "S2"])
    }

    @Test("asking for more speakers than the diarizer found changes nothing")
    func moreRequestedThanFound() {
        let input = DiarizationResult(
            segments: [seg(0, 100, "S1"), seg(100, 150, "S2")],
            speakerDatabase: ["S1": embedding(0), "S2": embedding(80)]
        )
        let out = SpeakerCountEnforcer.enforce(input, to: 4)
        #expect(speakers(out) == ["S1", "S2"])
        #expect(out.segments.count == 2)
        #expect(out.speakerDatabase.count == 2)
    }

    @Test("merging relabels turns and never drops them — total speech is preserved")
    func totalSpeechIsPreserved() {
        let input = DiarizationResult(
            segments: [
                seg(0, 40, "S1"), seg(40, 55, "S2"), seg(55, 95, "S1"),
                seg(95, 100, "S3"), seg(100, 108, "S4"),
            ],
            speakerDatabase: [
                "S1": embedding(0), "S2": embedding(30), "S3": embedding(55), "S4": embedding(90),
            ]
        )
        let out = SpeakerCountEnforcer.enforce(input, to: 2)
        #expect(speakers(out).count == 2)
        #expect(out.segments.count == input.segments.count)
        #expect(speech(out) == speech(input))
        // Boundaries must be untouched: this is a relabel, not a re-segmentation.
        #expect(out.segments.map(\.start) == input.segments.map(\.start))
        #expect(out.segments.map(\.end) == input.segments.map(\.end))
    }

    @Test("with no embeddings the smallest cluster folds into the dominant one")
    func fallsBackToDurationWithoutEmbeddings() {
        // FluidAudio returns an empty speaker database on some paths. Without embeddings there is
        // no "nearest", so the only defensible target is the cluster holding most of the speech.
        let input = DiarizationResult(
            segments: [seg(0, 100, "S1"), seg(100, 150, "S2"), seg(150, 160, "S3")],
            speakerDatabase: [:]
        )
        let out = SpeakerCountEnforcer.enforce(input, to: 2)
        #expect(speakers(out) == ["S1", "S2"])
        #expect(out.segments.first { $0.start == 150 }?.speaker == "S1")
    }

    @Test("a cluster with no embedding of its own still merges, by duration")
    func victimWithoutAnEmbedding() {
        let input = DiarizationResult(
            segments: [seg(0, 100, "S1"), seg(100, 150, "S2"), seg(150, 160, "S3")],
            speakerDatabase: ["S1": embedding(0), "S2": embedding(80)]
        )
        let out = SpeakerCountEnforcer.enforce(input, to: 2)
        #expect(speakers(out) == ["S1", "S2"])
        #expect(out.segments.first { $0.start == 150 }?.speaker == "S1")
    }

    @Test("a non-positive count is a no-op, not an empty transcript")
    func nonPositiveCountIsANoOp() {
        let input = DiarizationResult(
            segments: [seg(0, 100, "S1"), seg(100, 150, "S2")],
            speakerDatabase: ["S1": embedding(0), "S2": embedding(80)]
        )
        #expect(speakers(SpeakerCountEnforcer.enforce(input, to: 0)) == ["S1", "S2"])
        #expect(speakers(SpeakerCountEnforcer.enforce(input, to: -3)) == ["S1", "S2"])
    }

    @Test("an empty result is returned untouched")
    func emptyResult() {
        let out = SpeakerCountEnforcer.enforce(DiarizationResult(segments: []), to: 1)
        #expect(out.segments.isEmpty)
    }

    @Test("chained merges leave every turn on a surviving label")
    func chainedMergesResolve() {
        // S4 folds into S3 first; S3 must then carry both when it is itself absorbed. A mapping
        // that is not re-resolved would leave S4's turns pointing at a label that no longer exists.
        let input = DiarizationResult(
            segments: [seg(0, 200, "S1"), seg(200, 230, "S3"), seg(230, 236, "S4")],
            speakerDatabase: ["S1": embedding(0), "S3": embedding(70), "S4": embedding(72)]
        )
        let out = SpeakerCountEnforcer.enforce(input, to: 1)
        #expect(speakers(out) == ["S1"])
        #expect(out.segments.count == 3)
    }
}

// MARK: - Unattributed segments (#201 follow-up, device-found 2026-09-15)

@Suite("SpeakerCountEnforcer.foldUnattributed")
struct SpeakerCountEnforcerFoldTests {

    private func seg(_ speaker: String, _ start: Double = 0) -> LabeledSegment {
        LabeledSegment(start: start, end: start + 1, speaker: speaker, text: "x", source: "remote")
    }

    @Test("a stated count of 1 absorbs Unknown into the one speaker")
    func foldsAtOne() {
        let input = [seg("Speaker 1"), seg(SpeakerAssignment.unknownSpeaker, 2), seg("Speaker 1", 4)]
        let out = SpeakerCountEnforcer.foldUnattributed(input, statedCount: 1)
        #expect(Set(out.map(\.speaker)) == ["Speaker 1"])
        #expect(out.count == input.count)  // no segment dropped
    }

    @Test("at 2 or more the Unknown label is left alone — we cannot say whose it was")
    func leavesAloneAboveOne() {
        let input = [seg("Speaker 1"), seg(SpeakerAssignment.unknownSpeaker, 2), seg("Speaker 2", 4)]
        let out = SpeakerCountEnforcer.foldUnattributed(input, statedCount: 2)
        #expect(out.map(\.speaker) == input.map(\.speaker))
    }

    @Test("all-Unknown at a stated 1 still yields a named speaker, not a failure label")
    func namesAnAllUnknownChannel() {
        let input = [seg(SpeakerAssignment.unknownSpeaker), seg(SpeakerAssignment.unknownSpeaker, 2)]
        let out = SpeakerCountEnforcer.foldUnattributed(input, statedCount: 1)
        #expect(Set(out.map(\.speaker)) == ["Speaker 1"])
    }

    @Test("nothing to fold leaves the segments untouched")
    func noUnknownIsANoOp() {
        let input = [seg("Speaker 1"), seg("Speaker 1", 2)]
        let out = SpeakerCountEnforcer.foldUnattributed(input, statedCount: 1)
        #expect(out.map(\.speaker) == input.map(\.speaker))
    }
}
