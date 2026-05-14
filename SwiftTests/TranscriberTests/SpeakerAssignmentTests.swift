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
