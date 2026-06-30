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

    // MARK: - Retry policy (#50)

    @Test func isRetryableCoversRateLimitAndOverload() {
        #expect(OpenAISummaryProvider.isRetryable(429))
        #expect(OpenAISummaryProvider.isRetryable(503))
        #expect(!OpenAISummaryProvider.isRetryable(200))
        #expect(!OpenAISummaryProvider.isRetryable(400))
        #expect(!OpenAISummaryProvider.isRetryable(500))
    }

    @Test func parseRetryAfterSeconds() {
        #expect(OpenAISummaryProvider.parseRetryAfter("5") == 5)
        #expect(OpenAISummaryProvider.parseRetryAfter("  12 ") == 12)
        #expect(OpenAISummaryProvider.parseRetryAfter("-1") == nil)
        #expect(OpenAISummaryProvider.parseRetryAfter("not-a-number") == nil)
    }

    @Test func parseRetryAfterHTTPDate() throws {
        // A date ~10s in the future should yield a positive, near-10 wait.
        let future = Date().addingTimeInterval(10)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = f.string(from: future)
        let parsed = try #require(OpenAISummaryProvider.parseRetryAfter(header))
        #expect(parsed > 5 && parsed <= 11)
    }

    @Test func retryDelayUsesExponentialBackoffWhenNoHeader() {
        let provider = OpenAISummaryProvider(
            endpoint: "https://api.openai.com/v1", apiKey: "k", model: "m",
            session: .shared, retryBaseDelay: 1.0
        )
        let response = HTTPURLResponse(
            url: URL(string: "https://x")!, statusCode: 429, httpVersion: nil, headerFields: nil
        )!
        #expect(provider.retryDelay(attempt: 0, response: response) == 1)
        #expect(provider.retryDelay(attempt: 1, response: response) == 2)
        #expect(provider.retryDelay(attempt: 2, response: response) == 4)
    }

    @Test func retryDelayHonorsRetryAfterHeader() {
        let provider = OpenAISummaryProvider(
            endpoint: "https://api.openai.com/v1", apiKey: "k", model: "m",
            session: .shared, retryBaseDelay: 1.0
        )
        let response = HTTPURLResponse(
            url: URL(string: "https://x")!, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "7"]
        )!
        #expect(provider.retryDelay(attempt: 0, response: response) == 7)
    }
}

@Suite(.serialized)
struct OpenAISummaryProviderRetryTests {

    private func makeProvider() -> OpenAISummaryProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return OpenAISummaryProvider(
            endpoint: "https://api.openai.com/v1",
            apiKey: "sk-test",
            model: "gpt-4o-mini",
            session: session,
            retryBaseDelay: 0  // no real sleeping under test
        )
    }

    private let metadata = SummaryMetadata(
        sessionName: "test", date: Date(timeIntervalSince1970: 0),
        durationSeconds: 60, speakers: ["Alice"]
    )
    private let segments = [SummarySegment(start: 0, end: 5, speaker: "Alice", text: "hi")]

    private static func okBody() -> Data {
        """
        {"choices": [{"message": {"content": "## Summary\\nDone."}}]}
        """.data(using: .utf8)!
    }

    @Test func retriesOn429ThenSucceeds() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responses = [
            (429, ["Retry-After": "0"], Data("rate limited".utf8)),
            (200, [:], Self.okBody()),
        ]

        let provider = makeProvider()
        let content = try await provider.summarize(segments: segments, metadata: metadata)

        #expect(content.contains("Done."))
        #expect(MockURLProtocol.requestCount == 2)  // one 429, one success
    }

    @Test func retriesExhaustedThrows() async throws {
        MockURLProtocol.reset()
        // Always 429 — should give up after 1 initial + maxRetries attempts and throw.
        MockURLProtocol.responses = [(429, [:], Data("rate limited".utf8))]

        let provider = makeProvider()
        await #expect(throws: SummaryError.self) {
            _ = try await provider.summarize(segments: segments, metadata: metadata)
        }
        #expect(MockURLProtocol.requestCount == OpenAISummaryProvider.maxRetries + 1)
    }

    @Test func succeedsFirstTryWithoutRetry() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responses = [(200, [:], Self.okBody())]

        let provider = makeProvider()
        let content = try await provider.summarize(segments: segments, metadata: metadata)
        #expect(content.contains("Done."))
        #expect(MockURLProtocol.requestCount == 1)
    }
}

/// Minimal stub URLProtocol that replays a scripted sequence of responses. The last entry
/// is repeated for any further requests (so a single "always 429" entry covers all attempts).
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(status: Int, headers: [String: String], body: Data)] = []
    nonisolated(unsafe) static var requestCount = 0

    static func reset() {
        responses = []
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard !MockURLProtocol.responses.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let index = min(MockURLProtocol.requestCount, MockURLProtocol.responses.count - 1)
        MockURLProtocol.requestCount += 1
        let entry = MockURLProtocol.responses[index]
        let response = HTTPURLResponse(
            url: request.url!, statusCode: entry.status, httpVersion: "HTTP/1.1", headerFields: entry.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: entry.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
