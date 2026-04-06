import Testing
import Foundation
@testable import TranscriberCore

struct LMStudioSummaryProviderTests {

    @Test func buildsNativeAPIRequest() throws {
        let provider = LMStudioSummaryProvider(
            endpoint: "http://127.0.0.1:1234",
            apiKey: "",
            model: "gemma-4-e4b-it",
            contextLength: 24000
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
        let (request, inputChars, _) = try provider.buildRequest(segments: segments, metadata: metadata)

        #expect(request.url?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil) // empty key
        #expect(inputChars > 0)

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "gemma-4-e4b-it")
        // context_length is auto-sized: estimated input tokens + 1024 buffer, capped at 24000
        let ctx = body["context_length"] as! Int
        #expect(ctx > 0)
        #expect(ctx <= 24000)
        #expect(body["system_prompt"] as? String == OpenAISummaryProvider.systemPrompt)

        let input = body["input"] as! String
        #expect(input.contains("Alice: We need to ship by Friday"))
        #expect(input.contains("Meeting: standup"))
    }

    @Test func autoSizesContextFromContent() throws {
        let provider = LMStudioSummaryProvider(
            endpoint: "http://127.0.0.1:1234",
            apiKey: "",
            model: "test"
        )
        // ~300 chars of transcript → ~100 tokens estimated + system prompt ~300 tokens + 1024 buffer
        let segments = [SummarySegment(start: 0, end: 5, speaker: "A", text: "test")]
        let metadata = SummaryMetadata(sessionName: "t", date: Date(), durationSeconds: 5, speakers: ["A"])
        let (request, _, _) = try provider.buildRequest(segments: segments, metadata: metadata)

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let ctx = body["context_length"] as! Int
        // Small input: should be well under default 32768 cap
        #expect(ctx > 1024)  // at least the output buffer
        #expect(ctx < 5000)  // small input shouldn't request a huge context
    }

    @Test func capsContextAtUserLimit() throws {
        let provider = LMStudioSummaryProvider(
            endpoint: "http://127.0.0.1:1234",
            apiKey: "",
            model: "test",
            contextLength: 2000
        )
        // Even with small input, context should not exceed the user cap
        let segments = [SummarySegment(start: 0, end: 5, speaker: "A", text: String(repeating: "word ", count: 500))]
        let metadata = SummaryMetadata(sessionName: "t", date: Date(), durationSeconds: 5, speakers: ["A"])
        let (request, _, _) = try provider.buildRequest(segments: segments, metadata: metadata)

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let ctx = body["context_length"] as! Int
        #expect(ctx <= 2000)
    }

    @Test func buildsRequestWithAuth() throws {
        let provider = LMStudioSummaryProvider(
            endpoint: "http://127.0.0.1:1234",
            apiKey: "lms-abc123",
            model: "gemma-4-e4b-it"
        )
        let segments = [SummarySegment(start: 0, end: 5, speaker: "A", text: "test")]
        let metadata = SummaryMetadata(sessionName: "t", date: Date(), durationSeconds: 5, speakers: ["A"])
        let (request, _, _) = try provider.buildRequest(segments: segments, metadata: metadata)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer lms-abc123")
    }

    @Test func parsesNativeResponse() throws {
        let responseJSON = """
        {
            "model_instance_id": "inst-123",
            "output": [
                {
                    "type": "message",
                    "content": "## Executive Summary\\nA productive meeting about shipping."
                }
            ],
            "stats": {
                "input_tokens": 13705,
                "total_output_tokens": 450
            }
        }
        """.data(using: .utf8)!

        let (content, stats) = try LMStudioSummaryProvider.parseResponse(responseJSON)
        #expect(content == "## Executive Summary\nA productive meeting about shipping.")
        #expect(stats?.inputTokens == 13705)
        #expect(stats?.outputTokens == 450)
    }

    @Test func parsesResponseWithoutStats() throws {
        let responseJSON = """
        {
            "output": [
                {"type": "message", "content": "Summary here"}
            ]
        }
        """.data(using: .utf8)!

        let (content, stats) = try LMStudioSummaryProvider.parseResponse(responseJSON)
        #expect(content == "Summary here")
        #expect(stats == nil)
    }

    @Test func parseResponseThrowsOnEmptyOutput() throws {
        let responseJSON = """
        {"output": []}
        """.data(using: .utf8)!
        #expect(throws: SummaryError.self) {
            try LMStudioSummaryProvider.parseResponse(responseJSON)
        }
    }

    @Test func endpointStripsTrailingSlash() throws {
        let provider = LMStudioSummaryProvider(
            endpoint: "http://127.0.0.1:1234/",
            apiKey: "",
            model: "test"
        )
        let segments = [SummarySegment(start: 0, end: 1, speaker: "A", text: "hi")]
        let metadata = SummaryMetadata(sessionName: "t", date: Date(), durationSeconds: 1, speakers: ["A"])
        let (request, _, _) = try provider.buildRequest(segments: segments, metadata: metadata)
        #expect(request.url?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
    }

    // MARK: - Truncation detection

    @Test func detectsTruncationWhenOutputFillsAvailableSpace() {
        // Context 10000, input 8000 → 2000 available. Output 2000 = truncated
        #expect(LMStudioSummaryProvider.isLikelyTruncated(contextLength: 10000, inputTokens: 8000, outputTokens: 2000))
        // Within 5 tokens of limit also counts
        #expect(LMStudioSummaryProvider.isLikelyTruncated(contextLength: 10000, inputTokens: 8000, outputTokens: 1996))
    }

    @Test func doesNotFlagNormalOutput() {
        // Context 10000, input 8000 → 2000 available. Output 500 = plenty of room
        #expect(!LMStudioSummaryProvider.isLikelyTruncated(contextLength: 10000, inputTokens: 8000, outputTokens: 500))
    }

    @Test func doesNotFlagWhenInputExceedsContext() {
        // Edge case: input > context (shouldn't happen but be safe)
        #expect(!LMStudioSummaryProvider.isLikelyTruncated(contextLength: 5000, inputTokens: 6000, outputTokens: 100))
    }

    // MARK: - Dual-stream prompt injection

    @Test func dualStreamMetadataInjectsHintIntoSystemPrompt() throws {
        let provider = LMStudioSummaryProvider(
            endpoint: "http://127.0.0.1:1234",
            apiKey: "",
            model: "test"
        )
        let segments = [
            SummarySegment(start: 0, end: 5, speaker: "Alice", text: "Hello", source: "local"),
            SummarySegment(start: 5, end: 10, speaker: "Bob", text: "Hi", source: "remote"),
        ]
        let metadata = SummaryMetadata(
            sessionName: "standup",
            date: Date(timeIntervalSince1970: 0),
            durationSeconds: 10,
            speakers: ["Alice", "Bob"],
            dualStream: true
        )
        let (request, _, _) = try provider.buildRequest(segments: segments, metadata: metadata)

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let systemPrompt = body["system_prompt"] as! String
        #expect(systemPrompt.contains("Dual-Stream Audio Context"))
    }

    @Test func nonDualStreamMetadataOmitsHintFromSystemPrompt() throws {
        let provider = LMStudioSummaryProvider(
            endpoint: "http://127.0.0.1:1234",
            apiKey: "",
            model: "test"
        )
        let segments = [SummarySegment(start: 0, end: 5, speaker: "Alice", text: "Hello")]
        let metadata = SummaryMetadata(
            sessionName: "standup",
            date: Date(timeIntervalSince1970: 0),
            durationSeconds: 5,
            speakers: ["Alice"],
            dualStream: false
        )
        let (request, _, _) = try provider.buildRequest(segments: segments, metadata: metadata)

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let systemPrompt = body["system_prompt"] as! String
        #expect(!systemPrompt.contains("Dual-Stream Audio Context"))
    }

    // MARK: - Context error parsing

    @Test func parsesContextErrorTokenCount() {
        let body = """
        {"error":{"message":"The number of tokens to keep from the initial prompt is greater than the context length (n_keep: 19985>= n_ctx: 10240). Try to load the model with a larger context lengt"}}
        """
        #expect(LMStudioSummaryProvider.parseContextError(body) == 19985)
    }

    @Test func parsesContextErrorWithSpaces() {
        let body = "n_keep: 5000 >= n_ctx: 2048"
        #expect(LMStudioSummaryProvider.parseContextError(body) == 5000)
    }

    @Test func parseContextErrorReturnsNilForUnrelatedError() {
        let body = """
        {"error":{"message":"model not found"}}
        """
        #expect(LMStudioSummaryProvider.parseContextError(body) == nil)
    }

}
