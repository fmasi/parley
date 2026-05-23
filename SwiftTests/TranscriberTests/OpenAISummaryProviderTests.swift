import Testing
import Foundation
@testable import TranscriberCore

struct OpenAISummaryProviderTests {

    @Test func formatsTranscriptWithSpeakerLabels() {
        let segments = [
            SummarySegment(start: 0, end: 5.2, speaker: "Alice", text: "Hello everyone"),
            SummarySegment(start: 5.5, end: 12.0, speaker: "Bob", text: "Hi Alice, let's get started"),
        ]
        let formatted = OpenAISummaryProvider.formatTranscript(segments)
        #expect(formatted.contains("[00:00:00] Alice: Hello everyone"))
        #expect(formatted.contains("[00:00:05] Bob: Hi Alice, let's get started"))
    }

    @Test func buildsChatRequestBody() throws {
        let provider = OpenAISummaryProvider(
            endpoint: "https://api.openai.com/v1",
            apiKey: "sk-test",
            model: "gpt-4o-mini"
        )
        let segments = [
            SummarySegment(start: 0, end: 10, speaker: "Alice", text: "We need to ship by Friday"),
        ]
        let metadata = SummaryMetadata(
            sessionName: "standup",
            date: Date(timeIntervalSince1970: 0),
            durationSeconds: 600,
            speakers: ["Alice"]
        )
        let request = try provider.buildRequest(segments: segments, metadata: metadata)

        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.httpMethod == "POST")

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "gpt-4o-mini")
        let messages = body["messages"] as! [[String: String]]
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[1]["role"] == "user")
        #expect(messages[1]["content"]!.contains("Alice: We need to ship by Friday"))
    }

    @Test func buildsRequestWithoutAuthForEmptyApiKey() throws {
        let provider = OpenAISummaryProvider(
            endpoint: "http://localhost:11434/v1",
            apiKey: "",
            model: "llama3"
        )
        let segments = [SummarySegment(start: 0, end: 5, speaker: "A", text: "test")]
        let metadata = SummaryMetadata(sessionName: "t", date: Date(), durationSeconds: 5, speakers: ["A"])
        let request = try provider.buildRequest(segments: segments, metadata: metadata)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func parsesOpenAIResponse() throws {
        let responseJSON = """
        {
            "choices": [{
                "message": {
                    "content": "## Executive Summary\\nThis was a productive meeting."
                }
            }]
        }
        """.data(using: .utf8)!
        let content = try OpenAISummaryProvider.parseResponse(responseJSON)
        #expect(content == "## Executive Summary\nThis was a productive meeting.")
    }

    @Test func parseResponseThrowsOnEmptyChoices() throws {
        let responseJSON = """
        {"choices": []}
        """.data(using: .utf8)!
        #expect(throws: SummaryError.self) {
            try OpenAISummaryProvider.parseResponse(responseJSON)
        }
    }

    // MARK: - Dual-stream formatting

    @Test func formatTranscriptIncludesSourceTagsWhenEnabled() {
        let segments = [
            SummarySegment(start: 0, end: 5, speaker: "Alice", text: "Hello", source: "local"),
            SummarySegment(start: 5, end: 10, speaker: "Bob", text: "Hi there", source: "remote"),
        ]
        let formatted = OpenAISummaryProvider.formatTranscript(segments, includeSource: true)
        #expect(formatted.contains("Alice (local): Hello"))
        #expect(formatted.contains("Bob (remote): Hi there"))
    }

    @Test func formatTranscriptOmitsSourceTagsByDefault() {
        let segments = [
            SummarySegment(start: 0, end: 5, speaker: "Alice", text: "Hello", source: "local"),
            SummarySegment(start: 5, end: 10, speaker: "Bob", text: "Hi there", source: "remote"),
        ]
        let formatted = OpenAISummaryProvider.formatTranscript(segments)
        #expect(!formatted.contains("(local)"))
        #expect(!formatted.contains("(remote)"))
        #expect(formatted.contains("Alice: Hello"))
        #expect(formatted.contains("Bob: Hi there"))
    }

    @Test func dualStreamHintIsNonEmpty() {
        #expect(!OpenAISummaryProvider.dualStreamHint.isEmpty)
    }

    // MARK: - System prompt structure (skimmable, action-first template)

    @Test func systemPromptHasActionFirstSections() {
        let p = OpenAISummaryProvider.systemPrompt
        // The revised template leads with a metadata-bearing Summary, then the
        // actionable record, then supporting discussion.
        for section in ["### Summary", "### Decisions", "### Action Items", "### Discussion", "### Open Questions"] {
            #expect(p.contains(section), "missing section: \(section)")
        }
        // Old, buried-actionables sections are gone.
        #expect(!p.contains("### Executive Summary"))
        #expect(!p.contains("### Key Topics"))
    }

    @Test func systemPromptOrdersDecisionsBeforeDiscussion() {
        let p = OpenAISummaryProvider.systemPrompt
        guard let summary = p.range(of: "### Summary"),
              let decisions = p.range(of: "### Decisions"),
              let actions = p.range(of: "### Action Items"),
              let discussion = p.range(of: "### Discussion")
        else { Issue.record("sections not found"); return }
        // Skim order: Summary → Decisions → Action Items → Discussion.
        #expect(summary.lowerBound < decisions.lowerBound)
        #expect(decisions.lowerBound < actions.lowerBound)
        #expect(actions.lowerBound < discussion.lowerBound)
    }

    @Test func systemPromptEnforcesOwnerLedActionItems() {
        let p = OpenAISummaryProvider.systemPrompt
        // Owner-first checklist shape, and no manufactured "no date" placeholder.
        #expect(p.contains("<Owner>"))
        #expect(!p.contains("no date"))
    }

    @Test func systemPromptRestrictsDecisionsToExplicit() {
        // Curb the model's tendency to log discussion/intent as a "decision".
        #expect(OpenAISummaryProvider.systemPrompt.contains("explicit"))
    }
}
