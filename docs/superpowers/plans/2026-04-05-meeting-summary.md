# Meeting Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate structured meeting minutes from completed transcripts via an OpenAI-compatible LLM endpoint, with auto-trigger and CLI support.

**Architecture:** Provider protocol (`SummaryProvider`) with `OpenAISummaryProvider` implementation. `MeetingSummarizer` orchestrates: reads transcript, calls provider, writes `.md`. Config gets a `SummaryConfig` nested struct. Auto-trigger fires after transcript write in both `TranscriptionRunner.run()` and `TranscriptionRunner.finalize()`. CLI adds `summarize` subcommand.

**Tech Stack:** Swift, URLSession (no third-party HTTP), Swift Testing

---

### Task 1: SummaryProvider Protocol + Data Types

**Files:**
- Create: `TranscriberCore/SummaryProvider.swift`
- Test: `SwiftTests/TranscriberTests/MeetingSummarizerTests.swift`

- [ ] **Step 1: Create the protocol and data types**

Create `TranscriberCore/SummaryProvider.swift`:

```swift
import Foundation

public struct SummarySegment: Sendable {
    public let start: Double
    public let end: Double
    public let speaker: String
    public let text: String

    public init(start: Double, end: Double, speaker: String, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

public struct SummaryMetadata: Sendable {
    public let sessionName: String
    public let date: Date
    public let durationSeconds: Double
    public let speakers: [String]

    public init(sessionName: String, date: Date, durationSeconds: Double, speakers: [String]) {
        self.sessionName = sessionName
        self.date = date
        self.durationSeconds = durationSeconds
        self.speakers = speakers
    }
}

public protocol SummaryProvider: Sendable {
    func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Commit**

```bash
git add TranscriberCore/SummaryProvider.swift
git commit -m "feat: add SummaryProvider protocol and data types"
```

---

### Task 2: SummaryConfig + Config Integration

**Files:**
- Modify: `TranscriberCore/Config.swift`
- Modify: `SwiftTests/TranscriberTests/ConfigTests.swift`

- [ ] **Step 1: Write the failing test for SummaryConfig**

Add to `ConfigTests.swift`:

```swift
// MARK: - Summary config

@Test func summaryConfigDefaultsToNil() {
    let config = Config.default
    #expect(config.summary == nil)
}

@Test func summaryConfigRoundTrips() throws {
    var config = Config.default
    config.summary = SummaryConfig(
        enabled: true,
        endpoint: "https://api.openai.com/v1",
        apiKey: "sk-test",
        model: "gpt-4o-mini"
    )
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    #expect(decoded.summary?.enabled == true)
    #expect(decoded.summary?.endpoint == "https://api.openai.com/v1")
    #expect(decoded.summary?.apiKey == "sk-test")
    #expect(decoded.summary?.model == "gpt-4o-mini")
}

@Test func summaryConfigSnakeCaseKeys() throws {
    var config = Config.default
    config.summary = SummaryConfig(
        enabled: true,
        endpoint: "http://localhost:11434/v1",
        apiKey: "",
        model: "llama3"
    )
    let data = try JSONEncoder().encode(config)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let summaryJSON = json["summary"] as? [String: Any]
    #expect(summaryJSON != nil)
    #expect(summaryJSON?["api_key"] != nil)
}

@Test func decodesLegacyConfigWithoutSummary() throws {
    let json = """
    {"recording_directory":"/tmp","silence_timeout_minutes":5,"silence_detection_enabled":true,\
    "output_format":"txt","launch_on_startup":true,\
    "suppress_capture_warning":false}
    """
    let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    #expect(config.summary == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigTests 2>&1 | tail -10`
Expected: Compilation errors — `SummaryConfig` and `config.summary` don't exist yet.

- [ ] **Step 3: Add SummaryConfig and the summary field to Config**

In `Config.swift`, add the `SummaryConfig` struct before `Config`:

```swift
public struct SummaryConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var endpoint: String
    public var apiKey: String
    public var model: String

    public init(enabled: Bool, endpoint: String, apiKey: String, model: String) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case endpoint
        case apiKey = "api_key"
        case model
    }
}
```

Add to `Config` struct:
- Property: `public var summary: SummaryConfig?`
- Default: `summary: nil` in `Config.default` and `init()`
- CodingKey: `case summary`
- Decoder: `summary = try c.decodeIfPresent(SummaryConfig.self, forKey: .summary)`

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigTests 2>&1 | tail -10`
Expected: All tests pass (including new summary tests).

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/Config.swift SwiftTests/TranscriberTests/ConfigTests.swift
git commit -m "feat: add SummaryConfig to Config for LLM summary settings"
```

---

### Task 3: OpenAISummaryProvider

**Files:**
- Create: `TranscriberCore/OpenAISummaryProvider.swift`
- Create: `SwiftTests/TranscriberTests/OpenAISummaryProviderTests.swift`

- [ ] **Step 1: Write tests for request formatting and transcript formatting**

Create `SwiftTests/TranscriberTests/OpenAISummaryProviderTests.swift`:

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct OpenAISummaryProviderTests {

    // Test the transcript formatting helper (internal visibility via @testable)
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OpenAISummaryProviderTests 2>&1 | tail -10`
Expected: Compilation errors — `OpenAISummaryProvider` doesn't exist yet.

- [ ] **Step 3: Implement OpenAISummaryProvider**

Create `TranscriberCore/OpenAISummaryProvider.swift`:

```swift
import Foundation
import os

public enum SummaryError: LocalizedError {
    case invalidEndpoint(String)
    case requestFailed(String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let url): return "Invalid summary endpoint: \(url)"
        case .requestFailed(let msg): return "Summary request failed: \(msg)"
        case .emptyResponse: return "Summary response contained no content"
        }
    }
}

public struct OpenAISummaryProvider: SummaryProvider, Sendable {
    private let endpoint: String
    private let apiKey: String
    private let model: String

    public init(endpoint: String, apiKey: String, model: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
    }

    public func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
        let request = try buildRequest(segments: segments, metadata: metadata)
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SummaryError.requestFailed("HTTP \(httpResponse.statusCode): \(body.prefix(200))")
        }

        return try Self.parseResponse(data)
    }

    // MARK: - Internal (testable)

    func buildRequest(segments: [SummarySegment], metadata: SummaryMetadata) throws -> URLRequest {
        guard let url = URL(string: endpoint.hasSuffix("/")
            ? endpoint + "chat/completions"
            : endpoint + "/chat/completions")
        else {
            throw SummaryError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let transcript = Self.formatTranscript(segments)
        let userContent = """
        Meeting: \(metadata.sessionName)
        Date: \(Self.formatDate(metadata.date))
        Duration: \(Self.formatDuration(metadata.durationSeconds))
        Participants: \(metadata.speakers.joined(separator: ", "))

        --- TRANSCRIPT ---
        \(transcript)
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "temperature": 0.3
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func formatTranscript(_ segments: [SummarySegment]) -> String {
        segments.map { seg in
            let h = Int(seg.start) / 3600
            let m = (Int(seg.start) % 3600) / 60
            let s = Int(seg.start) % 60
            let ts = String(format: "[%02d:%02d:%02d]", h, m, s)
            return "\(ts) \(seg.speaker): \(seg.text)"
        }.joined(separator: "\n")
    }

    static func parseResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw SummaryError.emptyResponse
        }
        return content
    }

    private static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f.string(from: date)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static let systemPrompt = """
    You are an expert executive assistant producing concise meeting notes.
    Analyze the transcript and produce a structured summary in Markdown.

    ## Required Sections

    ### Executive Summary
    2-3 sentences capturing the overall purpose and outcome of the meeting.

    ### Key Topics
    Group discussion points by theme (not chronologically). For each topic, \
    write 1-3 sentences summarizing what was discussed. Attribute viewpoints \
    to speakers where relevant.

    ### Decisions
    List each decision made, who made or endorsed it, and brief context for why. \
    If no decisions were made, omit this section entirely.

    ### Action Items
    For each action item: who is responsible, what they need to do, and any \
    deadline mentioned. Format as a checklist. If no action items, omit this section entirely.

    ### Open Questions
    Unresolved topics or questions that need follow-up. Omit if none.

    ## Rules
    - Use speaker names exactly as they appear in the transcript
    - Do not invent information not present in the transcript
    - Do not include small talk, greetings, or off-topic banter
    - Keep the total summary under 500 words
    - Use professional, concise language
    """
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter OpenAISummaryProviderTests 2>&1 | tail -10`
Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/OpenAISummaryProvider.swift SwiftTests/TranscriberTests/OpenAISummaryProviderTests.swift
git commit -m "feat: implement OpenAISummaryProvider with chat completions API"
```

---

### Task 4: MeetingSummarizer Orchestrator

**Files:**
- Create: `TranscriberCore/MeetingSummarizer.swift`
- Modify: `SwiftTests/TranscriberTests/MeetingSummarizerTests.swift`

- [ ] **Step 1: Write tests with a mock provider**

Create `SwiftTests/TranscriberTests/MeetingSummarizerTests.swift`:

```swift
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

        // Create a minimal transcript JSON
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

        // Capture provider tracks what it received
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

    @Test func summarizeThrowsOnFailure() async throws {
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

        // No summary file written on failure
        let summaryPath = dir.appendingPathComponent("test-summary.md")
        #expect(!FileManager.default.fileExists(atPath: summaryPath.path))
    }
}

/// Test helper: captures provider inputs for assertion.
private final class CapturingProvider: SummaryProvider, @unchecked Sendable {
    private let handler: ([SummarySegment], SummaryMetadata) -> String
    init(handler: @escaping ([SummarySegment], SummaryMetadata) -> String) {
        self.handler = handler
    }
    func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
        handler(segments, metadata)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MeetingSummarizerTests 2>&1 | tail -10`
Expected: Compilation errors — `MeetingSummarizer` doesn't exist.

- [ ] **Step 3: Implement MeetingSummarizer**

Create `TranscriberCore/MeetingSummarizer.swift`:

```swift
import Foundation
import os

public enum MeetingSummarizer {

    /// Summarize a transcript JSON file and write a `-summary.md` alongside it.
    public static func summarize(
        transcriptPath: URL,
        provider: any SummaryProvider
    ) async throws {
        let (segments, metadata) = try parseTranscript(at: transcriptPath)

        Logger.transcription.info("Generating summary for '\(metadata.sessionName)' (\(segments.count) segments)")

        let markdown = try await provider.summarize(segments: segments, metadata: metadata)

        let summaryPath = transcriptPath.deletingPathExtension()
            .deletingLastPathComponent()
            .appendingPathComponent(
                transcriptPath.deletingPathExtension().lastPathComponent + "-summary.md"
            )
        try markdown.write(to: summaryPath, atomically: true, encoding: .utf8)

        Logger.transcription.info("Summary written to \(summaryPath.lastPathComponent)")
    }

    /// Convenience: create provider from config + summarize.
    public static func summarizeIfConfigured(
        transcriptPath: URL,
        config: Config
    ) async {
        guard let summary = config.summary, summary.enabled, !summary.endpoint.isEmpty else {
            return
        }

        let provider = OpenAISummaryProvider(
            endpoint: summary.endpoint,
            apiKey: summary.apiKey,
            model: summary.model
        )

        do {
            try await summarize(transcriptPath: transcriptPath, provider: provider)
        } catch {
            Logger.transcription.error("Summary generation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private static func parseTranscript(at path: URL) throws -> ([SummarySegment], SummaryMetadata) {
        let data = try Data(contentsOf: path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSegments = json["segments"] as? [[String: Any]]
        else {
            throw SummaryError.emptyResponse
        }

        let segments = rawSegments.map { seg in
            SummarySegment(
                start: seg["start"] as? Double ?? 0,
                end: seg["end"] as? Double ?? 0,
                speaker: seg["speaker"] as? String ?? "",
                text: seg["text"] as? String ?? ""
            )
        }

        // Extract unique speakers preserving order of first appearance
        var seen = Set<String>()
        var speakers: [String] = []
        for seg in segments {
            if !seg.speaker.isEmpty && seen.insert(seg.speaker).inserted {
                speakers.append(seg.speaker)
            }
        }

        let duration = segments.last?.end ?? 0
        let sessionName = path.deletingPathExtension().lastPathComponent

        let metadata = SummaryMetadata(
            sessionName: sessionName,
            date: Date(),
            durationSeconds: duration,
            speakers: speakers
        )

        return (segments, metadata)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MeetingSummarizerTests 2>&1 | tail -10`
Expected: All 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/MeetingSummarizer.swift SwiftTests/TranscriberTests/MeetingSummarizerTests.swift
git commit -m "feat: implement MeetingSummarizer orchestrator with mock-testable provider"
```

---

### Task 5: CLI `summarize` Subcommand

**Files:**
- Modify: `TranscriberCore/CLIParser.swift`
- Modify: `TranscriberApp/Services/CLIHandler.swift`
- Modify: `SwiftTests/TranscriberTests/CLIParserTests.swift` (if exists, otherwise create)

- [ ] **Step 1: Write the failing test for CLI parsing**

Check if `CLIParserTests.swift` exists. If not, create it. Add:

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct CLIParserTests {

    @Test func parsesSummarizeWithInput() throws {
        let cmd = try CLIParser.parse(["AudioTranscribe", "summarize", "-i", "/tmp/meeting.json"])
        guard case .summarize(let opts) = cmd else {
            Issue.record("Expected .summarize, got \(String(describing: cmd))")
            return
        }
        #expect(opts.input == "/tmp/meeting.json")
        #expect(opts.endpoint == nil)
        #expect(opts.apiKey == nil)
        #expect(opts.model == nil)
    }

    @Test func parsesSummarizeWithAllFlags() throws {
        let cmd = try CLIParser.parse([
            "AudioTranscribe", "summarize",
            "-i", "/tmp/meeting.json",
            "--endpoint", "http://localhost:11434/v1",
            "--api-key", "sk-test",
            "--model", "llama3"
        ])
        guard case .summarize(let opts) = cmd else {
            Issue.record("Expected .summarize")
            return
        }
        #expect(opts.input == "/tmp/meeting.json")
        #expect(opts.endpoint == "http://localhost:11434/v1")
        #expect(opts.apiKey == "sk-test")
        #expect(opts.model == "llama3")
    }

    @Test func summarizeMissingInputThrows() {
        #expect(throws: CLIParser.ParseError.self) {
            try CLIParser.parse(["AudioTranscribe", "summarize"])
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CLIParserTests 2>&1 | tail -10`
Expected: Compilation errors — `SummarizeOptions` and `.summarize` case don't exist.

- [ ] **Step 3: Add SummarizeOptions and parsing to CLIParser**

In `TranscriberCore/CLIParser.swift`:

Add the options struct (after `BenchmarkOptions`):
```swift
public struct SummarizeOptions {
    public let input: String
    public let endpoint: String?
    public let apiKey: String?
    public let model: String?
}
```

Add the enum case (in `CLICommand`):
```swift
case summarize(SummarizeOptions)
```

Add the switch case (in `parse(_:)`, before `default:`):
```swift
case "summarize":
    return .summarize(try parseSummarize(rest))
```

Add the parser method (after `parseBenchmark`):
```swift
private static func parseSummarize(_ args: [String]) throws -> SummarizeOptions {
    var input: String?
    var endpoint: String?
    var apiKey: String?
    var model: String?

    var i = 0
    while i < args.count {
        switch args[i] {
        case "-i", "--input":
            i += 1
            guard i < args.count else { throw ParseError.missingRequiredArg("-i") }
            input = args[i]
        case "--endpoint":
            i += 1
            guard i < args.count else { throw ParseError.missingRequiredArg("--endpoint") }
            endpoint = args[i]
        case "--api-key":
            i += 1
            guard i < args.count else { throw ParseError.missingRequiredArg("--api-key") }
            apiKey = args[i]
        case "--model":
            i += 1
            guard i < args.count else { throw ParseError.missingRequiredArg("--model") }
            model = args[i]
        default:
            break
        }
        i += 1
    }

    guard let input else { throw ParseError.missingRequiredArg("-i") }
    return SummarizeOptions(input: input, endpoint: endpoint, apiKey: apiKey, model: model)
}
```

- [ ] **Step 4: Add summarize handler to CLIHandler**

In `TranscriberApp/Services/CLIHandler.swift`:

Add case in the `switch command` block (after `.benchmark`):
```swift
case .summarize(let opts):
    try await handleSummarize(opts)
```

Add the handler method:
```swift
private static func handleSummarize(_ opts: SummarizeOptions) async throws {
    let jsonPath = URL(fileURLWithPath: opts.input)
    guard FileManager.default.fileExists(atPath: jsonPath.path) else {
        throw CLIError.fileNotFound(opts.input)
    }

    let config = ConfigManager.shared.config

    // CLI flags override config values
    let endpoint = opts.endpoint ?? config.summary?.endpoint
    let apiKey = opts.apiKey ?? config.summary?.apiKey ?? ""
    let model = opts.model ?? config.summary?.model

    guard let endpoint, let model else {
        fputs("Error: No endpoint/model configured. Use --endpoint and --model flags, or configure in Settings.\n", stderr)
        throw CLIError.missingConfig("summary endpoint and model")
    }

    let provider = OpenAISummaryProvider(endpoint: endpoint, apiKey: apiKey, model: model)
    try await MeetingSummarizer.summarize(transcriptPath: jsonPath, provider: provider)
    
    let summaryPath = jsonPath.deletingPathExtension().lastPathComponent + "-summary.md"
    print("Summary saved to: \(jsonPath.deletingLastPathComponent().appendingPathComponent(summaryPath).path)")
}
```

Add a new `CLIError` case:
```swift
case missingConfig(String)
```
With description:
```swift
case .missingConfig(let what): return "Missing configuration: \(what)"
```

Update `printUsage()` to include the new subcommand:
```
  summarize   Generate meeting summary from transcript
    -i <file>        Input JSON transcript (required)
    --endpoint <url> LLM endpoint URL (default: from config)
    --api-key <key>  API key (default: from config)
    --model <name>   Model name (default: from config)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter CLIParserTests 2>&1 | tail -10`
Expected: All 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add TranscriberCore/CLIParser.swift TranscriberApp/Services/CLIHandler.swift SwiftTests/TranscriberTests/CLIParserTests.swift
git commit -m "feat: add 'summarize' CLI subcommand for retroactive summary generation"
```

---

### Task 6: Auto-trigger in TranscriptionRunner

**Files:**
- Modify: `TranscriberApp/Services/TranscriptionRunner.swift`

- [ ] **Step 1: Add auto-trigger after transcript write in `run()` (single-chunk path)**

In `TranscriptionRunner.swift`, after the line `try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)` (around line 133), and after the archival block, before the final logging, add:

```swift
// Auto-summarize if configured (fire-and-forget)
Task.detached(priority: .utility) {
    await MeetingSummarizer.summarizeIfConfigured(transcriptPath: jsonPath, config: config)
}
```

- [ ] **Step 2: Add auto-trigger after transcript write in `finalize()` (chunked path)**

In `TranscriptionRunner.finalize()`, after `try TranscriptWriter.writeFormatFile(fromJSON: jsonPath)` (around line 249), add the same block:

```swift
// Auto-summarize if configured (fire-and-forget)
Task.detached(priority: .utility) {
    await MeetingSummarizer.summarizeIfConfigured(transcriptPath: jsonPath, config: config)
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded.

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Services/TranscriptionRunner.swift
git commit -m "feat: auto-trigger meeting summary after transcription when configured"
```

---

### Task 7: Settings UI for Summary Configuration

**Files:**
- Modify: `TranscriberApp/Views/SettingsView.swift`

- [ ] **Step 1: Add summary configuration section to SettingsView**

In `SettingsView.swift`, the `config` is `@State private var config: Config`. Since `config.summary` is optional, we need local state bindings. Add state variables after `archiveUsageBytes`:

```swift
@State private var summaryEnabled: Bool = false
@State private var summaryEndpoint: String = ""
@State private var summaryApiKey: String = ""
@State private var summaryModel: String = "gpt-4o-mini"
```

Update the `init` to populate them:
```swift
let s = configManager.config.summary
self._summaryEnabled = State(initialValue: s?.enabled ?? false)
self._summaryEndpoint = State(initialValue: s?.endpoint ?? "")
self._summaryApiKey = State(initialValue: s?.apiKey ?? "")
self._summaryModel = State(initialValue: s?.model ?? "gpt-4o-mini")
```

Add the section after the "Startup" section (before the closing `}` of `Form`):

```swift
Section("Meeting Summary") {
    Toggle("Auto-summarize after transcription", isOn: $summaryEnabled)
    if summaryEnabled {
        TextField("Endpoint URL", text: $summaryEndpoint)
            .textFieldStyle(.roundedBorder)
            .help("OpenAI-compatible endpoint (e.g. https://api.openai.com/v1 or http://localhost:11434/v1)")
        SecureField("API Key", text: $summaryApiKey)
            .textFieldStyle(.roundedBorder)
            .help("Leave empty for local providers like Ollama")
        TextField("Model", text: $summaryModel)
            .textFieldStyle(.roundedBorder)
    }
}
```

Update the Save button action to sync summary state back to config. In the `Button("Save")` closure, before `configManager.update`:

```swift
if summaryEnabled && !summaryEndpoint.isEmpty {
    config.summary = SummaryConfig(
        enabled: true,
        endpoint: summaryEndpoint,
        apiKey: summaryApiKey,
        model: summaryModel
    )
} else {
    config.summary = summaryEnabled ? config.summary : nil
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded.

- [ ] **Step 3: Commit**

```bash
git add TranscriberApp/Views/SettingsView.swift
git commit -m "feat: add Meeting Summary section to Settings UI"
```

---

### Task 8: Full Test Suite Run + Cleanup

**Files:** none new

- [ ] **Step 1: Run the full test suite**

Run: `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/ 2>&1 | tail -10`

Expected: All tests pass (324 + new tests).

- [ ] **Step 2: Verify the new files are in Package.swift**

The new `.swift` files are in `TranscriberCore/` and `SwiftTests/TranscriberTests/` — both are existing targets with directory-based source discovery, so no `Package.swift` changes needed. Verify:

Run: `swift build 2>&1 | tail -3`
Expected: Build succeeded.

- [ ] **Step 3: Update CLAUDE.md**

Add to the TranscriberCore file list:
```
- `TranscriberCore/SummaryProvider.swift` -- protocol for LLM summary providers + SummarySegment/SummaryMetadata types
- `TranscriberCore/OpenAISummaryProvider.swift` -- OpenAI-compatible chat completions provider (covers OpenAI, Ollama, LM Studio)
- `TranscriberCore/MeetingSummarizer.swift` -- orchestrator: reads transcript JSON, calls provider, writes -summary.md
```

Add `summarize` to CLIParser description:
```
- `TranscriberCore/CLIParser.swift` -- parses CLI arguments into CLICommand enum (transcribe, rename, renameGUI, benchmark, summarize) with typed option structs
```

Update test count in Build & Test section.

Add to Key Gotchas:
```
39. **Meeting summary fire-and-forget:** Auto-summary runs in a detached task after transcript write. Failures are logged but never block the pipeline or surface to the user. The summary is a derivative — the transcript is the canonical artifact.
40. **Summary provider protocol:** `SummaryProvider` takes segments + metadata (not a pre-formatted prompt). Each provider owns its own prompt strategy. This allows Apple Intelligence to use a fundamentally different API shape.
```

- [ ] **Step 4: Commit CLAUDE.md update**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with meeting summary architecture"
```
