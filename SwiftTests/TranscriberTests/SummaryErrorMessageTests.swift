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
