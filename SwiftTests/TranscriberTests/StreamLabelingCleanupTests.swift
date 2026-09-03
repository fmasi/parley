import Testing
import Foundation
@testable import TranscriberCore

/// The absorption rule (#65) has to run where BOTH transcription paths meet — `ChunkProcessor`
/// (live chunked pipeline) and `TranscriptionRunner` (recovery / one-shot) — or it is a fix applied
/// to one copy and silently missing from the other. `StreamLabeling` is that single point, and
/// these tests pin the wiring there rather than in either caller.
@Suite("StreamLabeling + DiarizationCleanup")
struct StreamLabelingCleanupTests {

    private func transcript(_ spans: [(Double, Double, String)]) -> [TranscriptSegment] {
        spans.map { TranscriptSegment(start: $0.0, end: $0.1, text: $0.2, language: "en", confidence: 0.9) }
    }

    /// The 2026-08-26 shape: one real speaker plus a 3.5% fragment.
    private func overSplitDiarization() -> DiarizationResult {
        DiarizationResult(
            segments: [
                DiarizedSegment(start: 0, end: 766, speaker: "S0", qualityScore: 1.0),
                DiarizedSegment(start: 766, end: 794, speaker: "S1", qualityScore: 1.0),
            ],
            speakerDatabase: ["S0": [1, 0], "S1": [0, 1]]
        )
    }

    @Test("labeling absorbs a minority cluster so it never reaches the transcript")
    func minorityClusterNeverReachesLabels() {
        let result = StreamLabeling.withDiarization(
            segments: transcript([(10, 20, "hello"), (770, 780, "still me")]),
            diarizationResult: overSplitDiarization(),
            speechMap: nil,
            vadSpeechThreshold: 0.5,
            minSpeakerShare: DiarizationCleanup.defaultMinShare
        )
        #expect(Set(result.labeled.map { $0.speaker }) == ["Speaker 1"])
    }

    @Test("the absorbed cluster is dropped from the speaker database too")
    func absorbedClusterLeavesNoEmbedding() {
        let result = StreamLabeling.withDiarization(
            segments: transcript([(10, 20, "hello"), (770, 780, "still me")]),
            diarizationResult: overSplitDiarization(),
            speechMap: nil,
            vadSpeechThreshold: 0.5,
            minSpeakerShare: DiarizationCleanup.defaultMinShare
        )
        // A stale embedding here would let the cross-chunk reconciler resurrect the fragment as a
        // global speaker in the next chunk — the exact 2026-08-26 symptom.
        #expect(result.speakerDatabase.count == 1)
    }

    @Test("a stated speaker count disables absorption and both clusters survive")
    func statedSpeakerCountPreservesMinorityCluster() {
        let result = StreamLabeling.withDiarization(
            segments: transcript([(10, 20, "hello"), (770, 780, "someone else")]),
            diarizationResult: overSplitDiarization(),
            speechMap: nil,
            vadSpeechThreshold: 0.5,
            minSpeakerShare: DiarizationCleanup.defaultMinShare,
            speakerCountIsUserStated: true
        )
        #expect(Set(result.labeled.map { $0.speaker }).count == 2)
        #expect(result.speakerDatabase.count == 2)
    }

    @Test("two genuine speakers are labeled separately, absorption or not")
    func genuineTwoSpeakerSplitSurvives() {
        let diar = DiarizationResult(
            segments: [
                DiarizedSegment(start: 0, end: 312, speaker: "S0", qualityScore: 1.0),
                DiarizedSegment(start: 312, end: 523, speaker: "S1", qualityScore: 1.0),
            ],
            speakerDatabase: ["S0": [1, 0], "S1": [0, 1]]
        )
        let result = StreamLabeling.withDiarization(
            segments: transcript([(10, 20, "mine"), (400, 410, "yours")]),
            diarizationResult: diar,
            speechMap: nil,
            vadSpeechThreshold: 0.5,
            minSpeakerShare: DiarizationCleanup.defaultMinShare
        )
        #expect(Set(result.labeled.map { $0.speaker }).count == 2)
    }
}
