import Testing
import Foundation
@testable import TranscriberCore

struct SummaryPromptBuilderTests {

    // MARK: - systemMessage

    @Test func systemMessageWithoutDualStreamIsJustTheSystemPrompt() {
        #expect(SummaryPromptBuilder.systemMessage(dualStream: false) == SummaryPromptBuilder.systemPrompt)
    }

    @Test func systemMessageWithDualStreamAppendsTheHint() {
        let msg = SummaryPromptBuilder.systemMessage(dualStream: true)
        #expect(msg == SummaryPromptBuilder.systemPrompt + SummaryPromptBuilder.dualStreamHint)
        #expect(msg.hasPrefix(SummaryPromptBuilder.systemPrompt))
        #expect(msg.contains("Dual-Stream Audio Context"))
    }

    // MARK: - userMessage

    @Test func userMessageBuildsMetadataHeaderThenTranscript() {
        let metadata = SummaryMetadata(
            sessionName: "standup",
            date: Date(timeIntervalSince1970: 0),
            durationSeconds: 3720,   // 1h 2m
            speakers: ["Alice", "Bob"]
        )
        let segments = [SummarySegment(start: 0, end: 5, speaker: "Alice", text: "hello")]

        let msg = SummaryPromptBuilder.userMessage(metadata: metadata, segments: segments)

        #expect(msg.contains("Meeting: standup"))
        #expect(msg.contains("Duration: 1h 2m"))
        #expect(msg.contains("Participants: Alice, Bob"))
        #expect(msg.contains("--- TRANSCRIPT ---"))
        #expect(msg.contains("Alice: hello"))
        // The metadata header must precede the transcript body.
        let headerIdx = msg.range(of: "Meeting: standup")!.lowerBound
        let transcriptIdx = msg.range(of: "--- TRANSCRIPT ---")!.lowerBound
        #expect(headerIdx < transcriptIdx)
    }

    @Test func userMessageTagsSourceOnlyWhenDualStream() {
        let segments = [SummarySegment(start: 0, end: 5, speaker: "Alice", text: "hi", source: "local")]

        let dual = SummaryPromptBuilder.userMessage(
            metadata: SummaryMetadata(sessionName: "c", date: Date(timeIntervalSince1970: 0),
                                      durationSeconds: 60, speakers: ["Alice"], dualStream: true),
            segments: segments
        )
        let single = SummaryPromptBuilder.userMessage(
            metadata: SummaryMetadata(sessionName: "c", date: Date(timeIntervalSince1970: 0),
                                      durationSeconds: 60, speakers: ["Alice"], dualStream: false),
            segments: segments
        )

        #expect(dual.contains("Alice (local): hi"))    // includeSource when dual-stream
        #expect(single.contains("Alice: hi"))
        #expect(!single.contains("(local)"))
    }
}
