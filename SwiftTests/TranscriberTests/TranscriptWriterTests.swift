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
            ["start": 8.039, "speaker": "Alice", "text": "Hello"],
            ["start": 11.959, "speaker": "Bob", "text": "Hi there"],
        ]
        let expected = "[00:00:08] Alice: Hello\n[00:00:11] Bob: Hi there\n"
        #expect(TranscriptWriter.formatTXT(segments: segments) == expected)
    }

    @Test func formatTXTEmptySpeakerOmitsPrefix() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "speaker": "", "text": "No speaker"],
        ]
        #expect(TranscriptWriter.formatTXT(segments: segments) == "[00:00:00] No speaker\n")
    }

    @Test func formatTXTMissingSpeakerKeyOmitsPrefix() {
        let segments: [[String: Any]] = [
            ["start": 0.0, "text": "No key"],
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

    @Test func writeFormatFileReflectsRenamedSpeakers() throws {
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
}
