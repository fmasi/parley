import Testing
import Foundation
@testable import TranscriberCore

/// What the user is TOLD when a summary fails.
///
/// This has been wrong twice in production. A `-1001` request timeout fell into a catch-all that
/// assumed any non-`SummaryError` was a file failure and reported "check disk space and
/// permissions" — sending two separate debugging sessions after a permissions problem that did not
/// exist (gotcha #66). A message that misdescribes the cause is worse than a vague one, because it
/// is actively followed.
@Suite struct SummaryErrorMessageTests {

    // MARK: - Auth failures must be actionable and must not leak the credential

    @Test func authFailureNamesTheApiKeyAndTheStatus() {
        let message = SummaryError.authenticationFailed(status: 401).localizedDescription
        #expect(message.contains("API key"))
        #expect(message.contains("401"))
    }

    /// The response body is deliberately NOT included: some servers echo the offending credential
    /// back, and this text reaches a notification that can be on screen during a shared meeting.
    /// The same concern already sanitizes `invalidEndpoint`.
    @Test func authFailureNeverEchoesAServerBody() {
        let leaky = "Bearer sk-lm-SECRETVALUE is not authorized"
        let message = SummaryError.authenticationFailed(status: 403).localizedDescription
        #expect(!message.contains("SECRETVALUE"))
        #expect(!message.contains(leaky))
        #expect(!message.lowercased().contains("bearer"))
    }

    @Test func forbiddenIsTreatedAsAnAuthFailureToo() {
        #expect(SummaryError.authenticationFailed(status: 403).localizedDescription.contains("API key"))
    }

    // MARK: - The distinctions that were missing

    /// Three different causes, three different instructions. Previously a timeout and an unreachable
    /// server both produced the file-permissions message.
    @Test func theThreeFailureKindsReadDifferently() {
        let auth = SummaryError.authenticationFailed(status: 401).localizedDescription
        let endpoint = SummaryError.invalidEndpoint("http://x").localizedDescription
        let server = SummaryError.serverError(message: "model failed to load", code: nil).localizedDescription

        #expect(auth != endpoint)
        #expect(auth != server)
        #expect(endpoint != server)
        // And none of them blames the filesystem.
        for m in [auth, endpoint, server] {
            #expect(!m.lowercased().contains("disk space"))
        }
    }

    /// The provider's own message survives for server-side faults — "model failed to load" is
    /// exactly the kind of detail that makes a failure diagnosable (#134).
    @Test func serverErrorForwardsTheProvidersOwnText() {
        let message = SummaryError.serverError(message: "model failed to load", code: "500")
            .localizedDescription
        #expect(message.contains("model failed to load"))
    }
}

/// The three `URLError` messages in `MeetingSummarizer.runSummary` are the literal fix for #173 —
/// a `-1001` timeout that fell through to the catch-all and was reported as *"check disk space and
/// permissions"*, sending two debugging sessions down the wrong path.
///
/// The provider-level tests above cannot protect them: this is about `runSummary`'s **catch order**.
/// Reshuffle the catches, or add a `SummaryError` case that matches before `URLError`, and the old
/// misdirecting message comes back with the rest of the suite still green.
@Suite("What runSummary tells the user when the network fails")
struct RunSummaryURLErrorTests {

    /// A provider that fails the way a local model server does.
    private struct ThrowingProvider: SummaryProvider {
        let error: any Error
        func summarize(segments: [SummarySegment], metadata: SummaryMetadata) async throws -> String {
            throw error
        }
    }

    private func transcript() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runsummary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("meeting.json")
        let doc: [String: Any] = [
            "metadata": [:],
            "segments": [["start": 0.0, "end": 2.0, "text": "hello", "speaker": "Speaker 1", "source": "local"]],
        ]
        try JSONSerialization.data(withJSONObject: doc).write(to: url)
        return url
    }

    private func outcome(for error: any Error) async throws -> SummaryOutcome {
        let url = try transcript()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return await MeetingSummarizer.runSummary(
            transcriptPath: url,
            provider: ThrowingProvider(error: error),
            endpoint: "http://127.0.0.1:1234")
    }

    @Test("a timeout blames the model, not the filesystem")
    func timeoutMessageNamesTheModel() async throws {
        guard case .failed(let message) = try await outcome(for: URLError(.timedOut)) else {
            Issue.record("expected .failed"); return
        }
        #expect(message.localizedCaseInsensitiveContains("too long"))
        // The exact regression: this used to say "check disk space and permissions".
        #expect(!message.localizedCaseInsensitiveContains("disk space"))
        #expect(!message.localizedCaseInsensitiveContains("permission"))
    }

    @Test("an unreachable server says so instead of blaming the transcript")
    func unreachableHostMessageNamesTheServer() async throws {
        for code in [URLError.Code.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet] {
            guard case .failed(let message) = try await outcome(for: URLError(code)) else {
                Issue.record("expected .failed for \(code)"); return
            }
            #expect(message.localizedCaseInsensitiveContains("reach"))
            #expect(!message.localizedCaseInsensitiveContains("disk space"))
        }
    }

    @Test("an unclassified URLError still avoids the file-failure wording")
    func unclassifiedURLErrorIsNotReportedAsAFileFailure() async throws {
        guard case .failed(let message) = try await outcome(for: URLError(.badServerResponse)) else {
            Issue.record("expected .failed"); return
        }
        #expect(!message.localizedCaseInsensitiveContains("disk space"))
        #expect(!message.localizedCaseInsensitiveContains("permission"))
    }
}
