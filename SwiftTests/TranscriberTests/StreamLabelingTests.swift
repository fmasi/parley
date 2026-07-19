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
        )

        #expect(!labeled.isEmpty)
        // Raw diarizer ID is remapped to the friendly label; the raw key is gone.
        #expect(speakerDatabase["Speaker 1"] == [1, 0, 0])
        #expect(speakerDatabase["S1"] == nil)
    }
}
