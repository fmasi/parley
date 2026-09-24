import Foundation
import Testing
@testable import TranscriberCore

/// L13 (§8.8): every helper call gets a deadline. `ResumeOnce` already guarantees a continuation is
/// resumed once; this adds "and not later than N seconds".
@Suite struct DeadlineTests {
    @Test func aFastBodyReturnsItsValue() async throws {
        let v = try await withDeadline(seconds: 1, label: "fast") { 42 }
        #expect(v == 42)
    }
    @Test func aSlowBodyThrowsTimedOutWithItsLabel() async {
        await #expect(throws: DeadlineError.timedOut("stop")) {
            try await withDeadline(seconds: 0.05, label: "stop") { try await Task.sleep(for: .seconds(10)); return 1 }
        }
    }
    @Test func aThrowingBodyRethrowsItsOwnError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await withDeadline(seconds: 1, label: "boom") { throw Boom() }
        }
    }
}
