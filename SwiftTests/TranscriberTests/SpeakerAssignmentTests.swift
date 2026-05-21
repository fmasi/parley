import Testing
import Foundation
@testable import TranscriberCore

struct SpeakerAssignmentTests {

    // MARK: - Deduplication

    @Test func deduplicateRemovesZeroDuration() {
        let segments = [
            TranscriptSegment(start: 0.0, end: 0.0, text: "ghost", language: nil),
            TranscriptSegment(start: 1.0, end: 2.0, text: "real", language: nil),
        ]
        let result = SpeakerAssignment.deduplicate(segments)
        #expect(result.count == 1)
        #expect(result[0].text == "real")
    }

    @Test func deduplicateRemovesConsecutiveDuplicates() {
        let segments = [
            TranscriptSegment(start: 0.0, end: 1.0, text: "hello", language: nil),
            TranscriptSegment(start: 1.0, end: 2.0, text: "hello", language: nil),
            TranscriptSegment(start: 2.0, end: 3.0, text: "world", language: nil),
        ]
        let result = SpeakerAssignment.deduplicate(segments)
        #expect(result.count == 2)
        #expect(result[0].text == "hello")
        #expect(result[1].text == "world")
    }

    @Test func deduplicateTrimsWhitespace() {
        let segments = [
            TranscriptSegment(start: 0.0, end: 1.0, text: " hello ", language: nil),
            TranscriptSegment(start: 1.0, end: 2.0, text: "hello", language: nil),
        ]
        let result = SpeakerAssignment.deduplicate(segments)
        #expect(result.count == 1)
    }

    @Test func deduplicatePreservesNonConsecutiveDuplicates() {
        let segments = [
            TranscriptSegment(start: 0.0, end: 1.0, text: "hello", language: nil),
            TranscriptSegment(start: 1.0, end: 2.0, text: "world", language: nil),
            TranscriptSegment(start: 2.0, end: 3.0, text: "hello", language: nil),
        ]
        let result = SpeakerAssignment.deduplicate(segments)
        #expect(result.count == 3)
    }

    // MARK: - Speaker Assignment

    @Test func assignSpeakersByOverlap() {
        let transcript = [
            TranscriptSegment(start: 0.0, end: 5.0, text: "hello", language: nil),
            TranscriptSegment(start: 5.0, end: 10.0, text: "world", language: nil),
        ]
        let diarization = [
            DiarizedSegment(start: 0.0, end: 6.0, speaker: "SPEAKER_00"),
            DiarizedSegment(start: 6.0, end: 10.0, speaker: "SPEAKER_01"),
        ]
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: diarization
        )
        #expect(result[0].speaker == "Speaker 1")
        #expect(result[1].speaker == "Speaker 2")
    }

    @Test func assignSpeakersMidpointTiebreaker() {
        let transcript = [
            TranscriptSegment(start: 0.0, end: 5.0, text: "test", language: nil),
        ]
        let diarization = [
            DiarizedSegment(start: 0.0, end: 3.0, speaker: "SPEAKER_00"),
            DiarizedSegment(start: 3.0, end: 5.0, speaker: "SPEAKER_01"),
        ]
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: diarization
        )
        #expect(result[0].speaker == "Speaker 1")
    }

    @Test func assignSpeakersUnknownWhenNoDiarization() {
        let transcript = [
            TranscriptSegment(start: 0.0, end: 5.0, text: "test", language: nil),
        ]
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: []
        )
        #expect(result[0].speaker == "Unknown")
    }

    @Test func assignSpeakersConsistentMapping() {
        let transcript = [
            TranscriptSegment(start: 0.0, end: 5.0, text: "first", language: nil),
            TranscriptSegment(start: 5.0, end: 10.0, text: "second", language: nil),
        ]
        let diarization = [
            DiarizedSegment(start: 0.0, end: 5.0, speaker: "SPEAKER_01"),
            DiarizedSegment(start: 5.0, end: 10.0, speaker: "SPEAKER_00"),
        ]
        let result = SpeakerAssignment.assign(
            transcriptSegments: transcript, diarizationSegments: diarization
        )
        #expect(result[0].speaker == "Speaker 1")
        #expect(result[1].speaker == "Speaker 2")
    }

    // MARK: - Dual-Stream Tagging

    @Test func tagSegmentsWithSource() {
        var segments = [
            LabeledSegment(start: 0.0, end: 1.0, speaker: "Speaker 1", text: "hi", source: "remote"),
        ]
        SpeakerAssignment.tagWithSourcePrefix(&segments)
        #expect(segments[0].speaker == "Remote Speaker 1")
    }

    @Test func tagSegmentsUnknownSpeakerGetsSourceOnly() {
        var segments = [
            LabeledSegment(start: 0.0, end: 1.0, speaker: "", text: "hi", source: "local"),
        ]
        SpeakerAssignment.tagWithSourcePrefix(&segments)
        #expect(segments[0].speaker == "Local")
    }

    // Regression: chunked finalize tags at chunk time (ChunkProcessor) and again
    // in TranscriptionRunner.finalize(); a second call must not double-prefix.
    @Test func tagSegmentsIsIdempotent() {
        var segments = [
            LabeledSegment(start: 0.0, end: 1.0, speaker: "Speaker 1", text: "hi", source: "local"),
            LabeledSegment(start: 1.0, end: 2.0, speaker: "Speaker 1", text: "yo", source: "remote"),
        ]
        SpeakerAssignment.tagWithSourcePrefix(&segments)
        SpeakerAssignment.tagWithSourcePrefix(&segments)
        #expect(segments[0].speaker == "Local Speaker 1")
        #expect(segments[1].speaker == "Remote Speaker 1")
    }

    @Test func tagSegmentsIsIdempotentForBareLabel() {
        var segments = [
            LabeledSegment(start: 0.0, end: 1.0, speaker: "", text: "hi", source: "local"),
        ]
        SpeakerAssignment.tagWithSourcePrefix(&segments)
        SpeakerAssignment.tagWithSourcePrefix(&segments)
        #expect(segments[0].speaker == "Local")
    }

    // MARK: - smoothDiarization

    // A <0.5s fragment of a distinct speaker (B) sandwiched between two longer
    // turns of speaker A should be absorbed into A, removing B entirely and then
    // merging the now-adjacent A turns into one.
    @Test func smoothAbsorbsShortFragmentBetweenLongerTurns() {
        let turns = [
            DiarizedSegment(start: 0.0, end: 5.0, speaker: "A"),
            DiarizedSegment(start: 5.0, end: 5.3, speaker: "B"),  // 0.3s fragment
            DiarizedSegment(start: 5.3, end: 10.0, speaker: "A"),
        ]
        let result = SpeakerAssignment.smoothDiarization(turns, minTurnDuration: 0.5)
        // B disappears; A turns merge into a single 0–10 turn.
        #expect(Set(result.map(\.speaker)) == ["A"])
        #expect(result.count == 1)
        #expect(result[0].start == 0.0)
        #expect(result[0].end == 10.0)
    }

    // A short fragment at the very start (only a next neighbor) is absorbed into
    // that neighbor.
    @Test func smoothAbsorbsShortFragmentAtStart() {
        let turns = [
            DiarizedSegment(start: 0.0, end: 0.2, speaker: "B"),  // 0.2s fragment
            DiarizedSegment(start: 0.2, end: 6.0, speaker: "A"),
        ]
        let result = SpeakerAssignment.smoothDiarization(turns, minTurnDuration: 0.5)
        #expect(result.count == 1)
        #expect(result[0].speaker == "A")
        #expect(result[0].start == 0.0)
        #expect(result[0].end == 6.0)
    }

    // A short fragment at the very end (only a previous neighbor) is absorbed
    // into that neighbor.
    @Test func smoothAbsorbsShortFragmentAtEnd() {
        let turns = [
            DiarizedSegment(start: 0.0, end: 6.0, speaker: "A"),
            DiarizedSegment(start: 6.0, end: 6.2, speaker: "B"),  // 0.2s fragment
        ]
        let result = SpeakerAssignment.smoothDiarization(turns, minTurnDuration: 0.5)
        #expect(result.count == 1)
        #expect(result[0].speaker == "A")
        #expect(result[0].start == 0.0)
        #expect(result[0].end == 6.2)
    }

    // The short turn is reassigned to the LONGER of its two neighbors.
    @Test func smoothAbsorbsIntoLongerNeighbor() {
        let turns = [
            DiarizedSegment(start: 0.0, end: 1.0, speaker: "A"),   // 1.0s
            DiarizedSegment(start: 1.0, end: 1.3, speaker: "B"),   // 0.3s fragment
            DiarizedSegment(start: 1.3, end: 6.0, speaker: "C"),   // 4.7s — dominant
        ]
        let result = SpeakerAssignment.smoothDiarization(turns, minTurnDuration: 0.5)
        // B absorbed into C (the longer neighbor); A and C remain distinct.
        #expect(result.count == 2)
        #expect(result[0].speaker == "A")
        #expect(result[1].speaker == "C")
        #expect(result[1].start == 1.0)
        #expect(result[1].end == 6.0)
    }

    // Adjacent same-speaker turns merge into one even without any short fragment.
    @Test func smoothMergesAdjacentSameSpeakerTurns() {
        let turns = [
            DiarizedSegment(start: 0.0, end: 3.0, speaker: "A"),
            DiarizedSegment(start: 3.0, end: 6.0, speaker: "A"),
            DiarizedSegment(start: 6.0, end: 9.0, speaker: "B"),
        ]
        let result = SpeakerAssignment.smoothDiarization(turns, minTurnDuration: 0.5)
        #expect(result.count == 2)
        #expect(result[0].speaker == "A")
        #expect(result[0].start == 0.0)
        #expect(result[0].end == 6.0)
        #expect(result[1].speaker == "B")
    }

    // A legitimately long turn for a distinct speaker is preserved — no over-merging.
    @Test func smoothPreservesLongDistinctTurns() {
        let turns = [
            DiarizedSegment(start: 0.0, end: 5.0, speaker: "A"),
            DiarizedSegment(start: 5.0, end: 10.0, speaker: "B"),
            DiarizedSegment(start: 10.0, end: 15.0, speaker: "A"),
        ]
        let result = SpeakerAssignment.smoothDiarization(turns, minTurnDuration: 0.5)
        #expect(result.count == 3)
        #expect(result.map(\.speaker) == ["A", "B", "A"])
    }

    @Test func smoothDefaultThresholdIsHalfSecond() {
        let turns = [
            DiarizedSegment(start: 0.0, end: 5.0, speaker: "A"),
            DiarizedSegment(start: 5.0, end: 5.4, speaker: "B"),  // 0.4s < default 0.5
            DiarizedSegment(start: 5.4, end: 10.0, speaker: "A"),
        ]
        let result = SpeakerAssignment.smoothDiarization(turns)
        #expect(result.count == 1)
        #expect(result[0].speaker == "A")
    }

    @Test func smoothEmptyAndSingleInputs() {
        #expect(SpeakerAssignment.smoothDiarization([]).isEmpty)
        let single = [DiarizedSegment(start: 0.0, end: 0.1, speaker: "A")]
        // Single short turn with no neighbors is left as-is (nothing to absorb into).
        let result = SpeakerAssignment.smoothDiarization(single)
        #expect(result.count == 1)
        #expect(result[0].speaker == "A")
    }

    // MARK: - buildSpeakerMap

    @Test func buildSpeakerMapMapsRawIDsToFriendlyNames() {
        let diarization = [
            DiarizedSegment(start: 0.0, end: 3.0, speaker: "S1"),
            DiarizedSegment(start: 3.0, end: 6.0, speaker: "S3"),
            DiarizedSegment(start: 6.0, end: 9.0, speaker: "S1"),
        ]
        let map = SpeakerAssignment.buildSpeakerMap(from: diarization)
        // First unique speaker seen → Speaker 1, second → Speaker 2
        #expect(map["S1"] == "Speaker 1")
        #expect(map["S3"] == "Speaker 2")
        #expect(map.count == 2)
    }

    @Test func buildSpeakerMapEmptyInput() {
        let map = SpeakerAssignment.buildSpeakerMap(from: [])
        #expect(map.isEmpty)
    }

    // MARK: - remapDatabaseKeys

    @Test func remapDatabaseKeysRenamesKnownKeys() {
        let database: [String: [Float]] = [
            "S1": [1.0, 0.5],
            "S3": [0.3, 0.8],
        ]
        let speakerMap = ["S1": "Speaker 1", "S3": "Speaker 2"]
        let remapped = SpeakerAssignment.remapDatabaseKeys(database, using: speakerMap)
        #expect(remapped["Speaker 1"] == [1.0, 0.5])
        #expect(remapped["Speaker 2"] == [0.3, 0.8])
        #expect(remapped["S1"] == nil)
        #expect(remapped["S3"] == nil)
    }

    @Test func remapDatabaseKeysPassesThroughUnknownKeys() {
        let database: [String: [Float]] = [
            "S1": [1.0],
            "UNKNOWN_ID": [0.5],
        ]
        let speakerMap = ["S1": "Speaker 1"]
        let remapped = SpeakerAssignment.remapDatabaseKeys(database, using: speakerMap)
        #expect(remapped["Speaker 1"] == [1.0])
        // Key not in map passes through unchanged
        #expect(remapped["UNKNOWN_ID"] == [0.5])
    }
}
