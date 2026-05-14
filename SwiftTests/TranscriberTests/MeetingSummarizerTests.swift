import Testing
import Foundation
@testable import TranscriberCore

struct MeetingSummarizerTests {

    private struct MockProvider: SummaryProvider {
        let response: String
        func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
            response
        }
    }

    private struct FailingProvider: SummaryProvider {
        func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
            throw SummaryError.requestFailed("network error")
        }
    }

    @Test func summarizeWritesMarkdownFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript: [String: Any] = [
            "metadata": [
                "audio_files": ["test.m4a"],
                "output_format": "txt",
                "language": "en",
                "diarization": true,
                "dual_stream": false
            ] as [String: Any],
            "segments": [
                ["start": 0.0, "end": 5.0, "speaker": "Alice", "text": "Ship it by Friday"] as [String: Any]
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: transcript)
        let jsonPath = dir.appendingPathComponent("meeting-2026.json")
        try jsonData.write(to: jsonPath)

        let provider = MockProvider(response: "## Executive Summary\nA productive meeting.")
        try await MeetingSummarizer.summarize(
            transcriptPath: jsonPath,
            provider: provider
        )

        let summaryPath = dir.appendingPathComponent("meeting-2026-summary.md")
        #expect(FileManager.default.fileExists(atPath: summaryPath.path))
        let content = try String(contentsOf: summaryPath, encoding: .utf8)
        #expect(content.contains("Executive Summary"))
    }

    @Test func summarizeExtractsSegmentsAndMetadata() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript: [String: Any] = [
            "metadata": [
                "audio_files": ["test.m4a"],
                "output_format": "txt",
                "language": "en",
                "diarization": true,
                "dual_stream": false
            ] as [String: Any],
            "segments": [
                ["start": 0.0, "end": 5.0, "speaker": "Alice", "text": "First point"] as [String: Any],
                ["start": 5.0, "end": 15.0, "speaker": "Bob", "text": "Second point"] as [String: Any],
                ["start": 15.0, "end": 20.0, "speaker": "Alice", "text": "Wrap up"] as [String: Any],
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: transcript)
        let jsonPath = dir.appendingPathComponent("standup.json")
        try jsonData.write(to: jsonPath)

        var receivedSegments: [SummarySegment] = []
        var receivedMetadata: SummaryMetadata?
        let provider = CapturingProvider { segments, metadata in
            receivedSegments = segments
            receivedMetadata = metadata
            return "## Summary"
        }
        try await MeetingSummarizer.summarize(transcriptPath: jsonPath, provider: provider)

        #expect(receivedSegments.count == 3)
        #expect(receivedSegments[0].speaker == "Alice")
        #expect(receivedSegments[1].text == "Second point")
        #expect(receivedMetadata?.speakers == ["Alice", "Bob"])
        #expect(receivedMetadata?.sessionName == "standup")
        #expect(receivedMetadata?.durationSeconds == 20.0)
    }

    @Test func summarizeThrowsOnProviderFailure() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript: [String: Any] = [
            "metadata": ["audio_files": [], "output_format": "txt", "language": "en",
                         "diarization": false, "dual_stream": false] as [String: Any],
            "segments": [
                ["start": 0, "end": 1, "speaker": "A", "text": "hi"] as [String: Any]
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: transcript)
        let jsonPath = dir.appendingPathComponent("test.json")
        try jsonData.write(to: jsonPath)

        let provider = FailingProvider()
        await #expect(throws: SummaryError.self) {
            try await MeetingSummarizer.summarize(transcriptPath: jsonPath, provider: provider)
        }

        let summaryPath = dir.appendingPathComponent("test-summary.md")
        #expect(!FileManager.default.fileExists(atPath: summaryPath.path))
    }

    // MARK: - SummarySegment / SummaryMetadata v0.7.x fields

    @Test func summarySegmentDefaultSource() {
        let seg = SummarySegment(start: 0, end: 1, speaker: "Alice", text: "hello")
        #expect(seg.source == "")
    }

    @Test func summaryMetadataDefaultDualStreamFields() {
        let meta = SummaryMetadata(sessionName: "test", date: Date(), durationSeconds: 60, speakers: ["A"])
        #expect(meta.dualStream == false)
        #expect(meta.echoSegmentsRemoved == 0)
    }

    @Test func summaryMetadataRecordsDualStreamFields() {
        let meta = SummaryMetadata(
            sessionName: "test", date: Date(), durationSeconds: 120, speakers: ["A", "B"],
            dualStream: true, echoSegmentsRemoved: 5
        )
        #expect(meta.dualStream == true)
        #expect(meta.echoSegmentsRemoved == 5)
    }

    @Test func summarizePopulatesDualStreamFromJSON() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summarizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript: [String: Any] = [
            "metadata": [
                "dual_stream": true,
                "echo_segments_removed": 7
            ] as [String: Any],
            "segments": [
                ["start": 0.0, "end": 5.0, "speaker": "Alice", "text": "Hi", "source": "local"] as [String: Any],
                ["start": 5.0, "end": 10.0, "speaker": "Bob", "text": "Hello", "source": "remote"] as [String: Any],
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: transcript)
        let jsonPath = dir.appendingPathComponent("dual.json")
        try jsonData.write(to: jsonPath)

        var capturedMeta: SummaryMetadata?
        var capturedSegs: [SummarySegment] = []
        let provider = CapturingProvider { segments, metadata in
            capturedSegs = segments
            capturedMeta = metadata
            return "## Summary"
        }
        try await MeetingSummarizer.summarize(transcriptPath: jsonPath, provider: provider)

        #expect(capturedMeta?.dualStream == true)
        #expect(capturedMeta?.echoSegmentsRemoved == 7)
        #expect(capturedSegs[0].source == "local")
        #expect(capturedSegs[1].source == "remote")
    }
}

private final class CapturingProvider: SummaryProvider, @unchecked Sendable {
    private let handler: ([SummarySegment], SummaryMetadata) -> String
    init(handler: @escaping ([SummarySegment], SummaryMetadata) -> String) {
        self.handler = handler
    }
    func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
        handler(segments, metadata)
    }
}
