import Testing
import Foundation
@testable import TranscriberCore

struct TranscriptWriterTests {

    // MARK: - Timestamp formatting

    @Test func formatTimestampZero() {
        #expect(TranscriptWriter.formatTimestamp(0) == "00:00:00,000")
    }

    @Test func formatTimestampWithMilliseconds() {
        #expect(TranscriptWriter.formatTimestamp(8.039) == "00:00:08,039")
    }

    @Test func formatTimestampMinutesAndHours() {
        #expect(TranscriptWriter.formatTimestamp(3661.5) == "01:01:01,500")
    }

    @Test func formatTimestampShortZero() {
        #expect(TranscriptWriter.formatTimestampShort(0) == "00:00:00")
    }

    @Test func formatTimestampShortTruncatesMillis() {
        #expect(TranscriptWriter.formatTimestampShort(8.039) == "00:00:08")
    }

    @Test func formatTimestampShortMinutesAndHours() {
        #expect(TranscriptWriter.formatTimestampShort(3661.5) == "01:01:01")
    }

    // MARK: - SRT formatting

    @Test func formatSRTMultipleSegments() {
        let segments: [[String: Any]] = [
            ["start": 8.039, "end": 9.039, "speaker": "Alice", "text": "Hello"],
            ["start": 11.959, "end": 29.579, "speaker": "Bob", "text": "Hi there"],
        ]
        let expected = "1\n00:00:08,039 --> 00:00:09,039\nAlice: Hello\n\n2\n00:00:11,959 --> 00:00:29,579\nBob: Hi there\n\n"
        #expect(TranscriptWriter.formatSRT(segments: segments) == expected)
    }

    @Test func formatSRTEmptySpeakerOmitsPrefix() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 1.0, "speaker": "", "text": "No speaker"],
        ]
        let expected = "1\n00:00:00,000 --> 00:00:01,000\nNo speaker\n\n"
        #expect(TranscriptWriter.formatSRT(segments: segments) == expected)
    }

    @Test func formatSRTMissingSpeakerKeyOmitsPrefix() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 1.0, "text": "No key"],
        ]
        let expected = "1\n00:00:00,000 --> 00:00:01,000\nNo key\n\n"
        #expect(TranscriptWriter.formatSRT(segments: segments) == expected)
    }

    // MARK: - TXT formatting

    @Test func formatTXTMultipleSegments() {
        let segments: [[String: Any]] = [
            ["start": 8.039, "end": 9.0, "speaker": "Alice", "text": "Hello"],
            ["start": 11.959, "end": 13.0, "speaker": "Bob", "text": "Hi there"],
        ]
        let expected = "[00:00:08] Alice: Hello\n[00:00:11] Bob: Hi there\n"
        #expect(TranscriptWriter.formatTXT(segments: segments) == expected)
    }

    @Test func formatTXTEmptySpeakerOmitsPrefix() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 1.0, "speaker": "", "text": "No speaker"],
        ]
        #expect(TranscriptWriter.formatTXT(segments: segments) == "[00:00:00] No speaker\n")
    }

    @Test func formatTXTMissingSpeakerKeyOmitsPrefix() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 1.0, "text": "No key"],
        ]
        #expect(TranscriptWriter.formatTXT(segments: segments) == "[00:00:00] No key\n")
    }

    // MARK: - writeFormatFile

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-test-\(UUID().uuidString)")
    }

    private func createJSON(in dir: URL, metadata: [String: Any], segments: [[String: Any]]) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json: [String: Any] = ["metadata": metadata, "segments": segments]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let path = dir.appendingPathComponent("test.json")
        try data.write(to: path)
        return path
    }

    @Test func writeFormatFileSRT() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let segments: [[String: Any]] = [
            ["start": 1.0, "end": 2.0, "speaker": "Alice", "text": "Hello"],
        ]
        let jsonPath = try createJSON(in: dir, metadata: ["output_format": "srt"], segments: segments)

        try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)

        let srtPath = dir.appendingPathComponent("test.srt")
        let content = try String(contentsOf: srtPath, encoding: .utf8)
        #expect(content.contains("Alice: Hello"))
        #expect(content.contains("00:00:01,000 --> 00:00:02,000"))
    }

    @Test func writeFormatFileTXT() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let segments: [[String: Any]] = [
            ["start": 1.0, "end": 2.0, "speaker": "Bob", "text": "Hi"],
        ]
        let jsonPath = try createJSON(in: dir, metadata: ["output_format": "txt"], segments: segments)

        try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)

        let txtPath = dir.appendingPathComponent("test.txt")
        let content = try String(contentsOf: txtPath, encoding: .utf8)
        #expect(content == "[00:00:01] Bob: Hi\n")
    }

    @Test func writeFormatFileJSONIsNoop() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonPath = try createJSON(in: dir, metadata: ["output_format": "json"], segments: [])

        try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)

        // No extra file should be created
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(contents.count == 1) // only the .json
    }

    @Test func writeFormatFilePreservesSpeakerNames() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let segments: [[String: Any]] = [
            ["start": 0.0, "end": 1.0, "speaker": "Frederic", "text": "Hello"],
            ["start": 1.0, "end": 2.0, "speaker": "Remote Speaker 1", "text": "Hi"],
        ]
        let jsonPath = try createJSON(in: dir, metadata: ["output_format": "srt"], segments: segments)

        try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)

        let srtPath = dir.appendingPathComponent("test.srt")
        let content = try String(contentsOf: srtPath, encoding: .utf8)
        #expect(content.contains("Frederic: Hello"))
        #expect(content.contains("Remote Speaker 1: Hi"))
    }

    @Test func writeFormatFileMissingFormatDefaultsToNoOp() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonPath = try createJSON(in: dir, metadata: [:], segments: [])

        try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)

        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(contents.count == 1) // only the .json
    }

    @Test func flaggedSegmentsAreHiddenInTxtAndSrt() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segments: [[String: Any]] = [
            ["start": 1.0, "end": 2.0, "speaker": "Alice", "text": "Hello"],
            ["start": 2.0, "end": 3.0, "speaker": "Unknown", "text": "noise", "filtered": true],
            ["start": 3.0, "end": 4.0, "speaker": "Bob", "text": "Hello", "echo": true],
        ]
        let jsonPath = try createJSON(in: dir, metadata: ["output_format": "srt"], segments: segments)
        try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)
        let srt = try String(contentsOf: dir.appendingPathComponent("test.srt"), encoding: .utf8)
        #expect(srt.contains("Alice: Hello") && !srt.contains("noise") && !srt.contains("Bob"))
        let txt = TranscriptWriter.formatTXT(segments: segments)
        #expect(txt.contains("Alice") && !txt.contains("noise") && !txt.contains("Bob"))
    }

    @Test func duplicateFlaggedSegmentsAreHidden() {
        let txt = TranscriptWriter.formatTXT(segments: [
            ["start": 1.0, "end": 2.0, "speaker": "Alice", "text": "No."],
            ["start": 2.1, "end": 3.0, "speaker": "Alice", "text": "No again", "duplicate": true],
        ])
        #expect(txt.contains("No.") && !txt.contains("No again"))
    }

    /// R2b item 5: a segment whose time is missing or non-finite (written as null) was rendered at
    /// 00:00:00 — a false time. It is skipped (the JSON keeps it, flagged `time_unknown`), never 0.
    @Test func aSegmentWithoutATimeIsSkippedNeverAtZero() {
        let segments: [[String: Any]] = [
            ["start": 1.0, "end": 2.0, "speaker": "Alice", "text": "timed"],
            ["start": NSNull(), "end": NSNull(), "speaker": "Alice", "text": "null time", "time_unknown": true],
            ["end": 4.0, "speaker": "Bob", "text": "no start"],
            ["start": 5.0, "end": "later", "speaker": "Bob", "text": "text end"],
        ]
        // Round 3 item 8: the TXT itself says what it left out, not only the log. The SRT stays pure
        // cues (round 3b: strict parsers reject a plain line after the last cue); the JSON has them.
        let txt = TranscriptWriter.formatTXT(segments: segments)
        #expect(txt == "[00:00:01] Alice: timed\n\nNote: 3 segments without timestamps are in the JSON transcript.\n")
        let srt = TranscriptWriter.formatSRT(segments: segments)
        #expect(srt == "1\n00:00:01,000 --> 00:00:02,000\nAlice: timed\n\n")
        let one = TranscriptWriter.formatTXT(segments: [segments[0], segments[1]])
        #expect(one.hasSuffix("Note: 1 segment without a timestamp is in the JSON transcript.\n"))
        #expect(TranscriptWriter.formatTXT(segments: [segments[0]]) == "[00:00:01] Alice: timed\n", "no note when nothing was left out")
        #expect(TranscriptAssembler.isFlagged(segments[1]) && TranscriptAssembler.isFlagged(segments[2]) && TranscriptAssembler.isFlagged(segments[3]))
    }
}
