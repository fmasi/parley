import Foundation
import Testing
@testable import TranscriberCore

/// #135 H2: each per-segment WAV in a crash-recovered / CLI multi-segment run starts at its own
/// t=0. Without a cumulative offset, segment 2's minute-2 line collides with segment 1's minute-2
/// line in the merged transcript. `segmentStartOffsets` is the pure, unit-tested guarantee that
/// `run()` turns each segment's file-relative timestamps into absolute ones.
@Suite struct TranscriptionRunnerTests {

    @Test func cumulativeOffsets() {
        #expect(TranscriptionRunner.segmentStartOffsets(durations: [60, 45, 30]) == [0, 60, 105])
    }

    @Test func singleSegmentHasNoOffset() {
        #expect(TranscriptionRunner.segmentStartOffsets(durations: [42]) == [0])
    }

    @Test func noSegmentsYieldsNoOffsets() {
        #expect(TranscriptionRunner.segmentStartOffsets(durations: []) == [])
    }
}

/// #135 H3: each recovery/CLI segment is diarized independently, so segment 0's "Speaker 1" and
/// segment 1's "Speaker 1" are unrelated raw labels — they may be the SAME person or two DIFFERENT
/// people. `reconcileRecoverySegments` reuses `SpeakerReconciler`'s cosine matching (rather than a
/// hand-rolled comparator) to decide which, and returns a segment-namespaced mapping so `run()` can
/// relabel every segment's segments into one consistent global namespace before merging.
@Suite struct TranscriptionRunnerReconciliationTests {

    @Test func crossSegmentIdentityYieldsTwoSpeakers() {
        // Two segments, each a single speaker under the same raw label "Speaker 1", but with
        // far-apart embeddings — i.e. two different people who both happened to be diarized as
        // "Speaker 1" locally. Must NOT collapse into one global speaker.
        let mapping = TranscriptionRunner.reconcileRecoverySegments(
            databases: [
                ["Speaker 1": [1, 0, 0]],
                ["Speaker 1": [0, 1, 0]],
            ],
            threshold: 0.65
        )
        #expect(Set(mapping.values).count == 2)
    }

    @Test func crossSegmentMatchingVoiceprintYieldsOneSpeaker() {
        // Same person's voiceprint (near-identical embedding) reappearing under "Speaker 1" in
        // both segments must reconcile to the SAME global label.
        let mapping = TranscriptionRunner.reconcileRecoverySegments(
            databases: [
                ["Speaker 1": [1, 0, 0]],
                ["Speaker 1": [0.99, 0.01, 0]],
            ],
            threshold: 0.65
        )
        #expect(Set(mapping.values).count == 1)
    }
}
