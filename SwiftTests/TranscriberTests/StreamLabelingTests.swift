import Testing
import Foundation
@testable import TranscriberCore

struct StreamLabelingTests {

    // MARK: - singleSpeaker

    @Test func singleSpeakerLabelsEverySegmentWithTheGivenSpeaker() {
        let segs = [
            TranscriptSegment(start: 0, end: 1, text: "  hello  ", language: "en", confidence: 0.9),
            TranscriptSegment(start: 1, end: 2, text: "world", language: nil, confidence: nil),
        ]

        let labeled = StreamLabeling.singleSpeaker(segs, speaker: "Speaker 1")

        #expect(labeled.count == 2)
        #expect(labeled.allSatisfy { $0.speaker == "Speaker 1" })
        #expect(labeled[0].text == "hello")   // trimmed
        #expect(labeled[0].source == "")      // source is stamped by the caller afterwards
        #expect(labeled[0].start == 0 && labeled[0].end == 1)
        #expect(labeled[0].confidence == 0.9)
        #expect(labeled[0].language == "en")
        #expect(labeled[1].language == nil)
    }

    @Test func singleSpeakerHonorsTheUnknownLabel() {
        let labeled = StreamLabeling.singleSpeaker(
            [TranscriptSegment(start: 0, end: 1, text: "x", language: nil)],
            speaker: SpeakerAssignment.unknownSpeaker
        )
        #expect(labeled.first?.speaker == "Unknown")
    }

    @Test func singleSpeakerOnEmptyInputReturnsEmpty() {
        #expect(StreamLabeling.singleSpeaker([], speaker: "Speaker 1").isEmpty)
    }

    // MARK: - withDiarization

    // The distinguishing behaviour of withDiarization (over a plain assign) is that it remaps the
    // speaker-database keys from the diarizer's raw IDs ("S1") to the friendly names ("Speaker 1")
    // used in the labeled segments, so downstream echo dedup / reconciliation can match them.
    @Test func withDiarizationRemapsSpeakerDatabaseKeysToFriendlyNames() {
        let result = DiarizationResult(
            segments: [DiarizedSegment(start: 0, end: 5, speaker: "S1")],
            speakerDatabase: ["S1": [1, 0, 0]]
        )

        let (labeled, speakerDatabase) = StreamLabeling.withDiarization(
            segments: [TranscriptSegment(start: 0, end: 5, text: "hi", language: nil)],
            diarizationResult: result,
            speechMap: nil,
            vadSpeechThreshold: 0.5
        , minSpeakerShare: DiarizationCleanup.defaultMinShare)

        #expect(!labeled.isEmpty)
        // Raw diarizer ID is remapped to the friendly label; the raw key is gone.
        #expect(speakerDatabase["Speaker 1"] == [1, 0, 0])
        #expect(speakerDatabase["S1"] == nil)
    }

    // Two diarizer speakers: the database keys must remap in the order the speakers first appear
    // in `diarizationResult.segments` — the array, not Dictionary insertion order (S1→Speaker 1,
    // S2→Speaker 2) — and agree with the labels (the invariant documented on withDiarization).
    @Test func withDiarizationRemapsAllSpeakersInSegmentOrder() {
        let result = DiarizationResult(
            segments: [
                DiarizedSegment(start: 0, end: 3, speaker: "S1"),
                DiarizedSegment(start: 3, end: 6, speaker: "S2"),
            ],
            speakerDatabase: ["S1": [1, 0], "S2": [0, 1]]
        )

        let (labeled, db) = StreamLabeling.withDiarization(
            segments: [
                TranscriptSegment(start: 0, end: 3, text: "a", language: nil),
                TranscriptSegment(start: 3, end: 6, text: "b", language: nil),
            ],
            diarizationResult: result, speechMap: nil, vadSpeechThreshold: 0.5
        , minSpeakerShare: DiarizationCleanup.defaultMinShare)

        // The segment labels and the database keys must agree — the documented invariant.
        #expect(labeled.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(db["Speaker 1"] == [1, 0])
        #expect(db["Speaker 2"] == [0, 1])
        #expect(db["S1"] == nil)
        #expect(db["S2"] == nil)
    }

    // Empty diarization (no speakers at all): withDiarization must return an empty database and
    // not crash on the empty remap — the withDiarization analogue of singleSpeaker's empty test.
    @Test func withDiarizationOnEmptyDiarizationReturnsEmptyDatabase() {
        let (_, db) = StreamLabeling.withDiarization(
            segments: [TranscriptSegment(start: 0, end: 1, text: "x", language: nil)],
            diarizationResult: DiarizationResult(segments: [], speakerDatabase: [:]),
            speechMap: nil,
            vadSpeechThreshold: 0.5
        , minSpeakerShare: DiarizationCleanup.defaultMinShare)
        #expect(db.isEmpty)
    }

    // Proves withDiarization actually forwards speechMap/threshold to assign() rather than
    // ignoring them. Same diarized segment both ways; only speechMap changes:
    //  - nil speechMap → VAD/quality gating is bypassed entirely → keeps "Speaker 1".
    //  - non-nil speechMap with HIGH speech overlap (0.95 ≥ the 0.5 threshold) passes the speech
    //    check, so the low quality score becomes the deciding factor and demotes the segment to
    //    "Unknown". The quality cutoff is assign()'s default qualityScoreThreshold (0.3, and
    //    0.1 < 0.3) — this test deliberately pins assign()'s real gating contract; if that default
    //    ever changes, update the qualityScore here to stay clearly below it. (Both the speech
    //    overlap and the sub-threshold quality are load-bearing.)
    @Test func withDiarizationForwardsSpeechMap() {
        let segs = [TranscriptSegment(start: 0, end: 5, text: "hello", language: nil)]
        let result = DiarizationResult(
            segments: [DiarizedSegment(start: 0, end: 5, speaker: "SPEAKER_00", qualityScore: 0.1)],
            speakerDatabase: ["SPEAKER_00": [1, 0, 0]]
        )

        let (nilMap, _) = StreamLabeling.withDiarization(
            segments: segs, diarizationResult: result, speechMap: nil, vadSpeechThreshold: 0.5
        , minSpeakerShare: DiarizationCleanup.defaultMinShare)
        let (withMap, _) = StreamLabeling.withDiarization(
            segments: segs, diarizationResult: result,
            speechMap: [SpeechRegion(start: 0, end: 5, probability: 0.95)], vadSpeechThreshold: 0.5
        , minSpeakerShare: DiarizationCleanup.defaultMinShare)

        #expect(nilMap.first?.speaker == "Speaker 1")
        #expect(withMap.first?.speaker == "Unknown")
    }
}
