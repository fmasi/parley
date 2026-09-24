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

    /// H2 round 2 (council B-M13): a body that wins leaves no sleeper behind. Before, the sleeper ran
    /// out its whole deadline (20 s after a stop) — idle wakeups with nothing recording.
    @Test func aFastBodyCancelsTheSleeper() async throws {
        let sleeperCancelled = AsyncStream<Bool>.makeStream()
        let v = try await withDeadline(seconds: 30, label: "fast", sleeper: { seconds in
            do {
                try await Task.sleep(for: .seconds(seconds))
                sleeperCancelled.continuation.yield(false)
            } catch {
                sleeperCancelled.continuation.yield(true)
            }
            sleeperCancelled.continuation.finish()
        }) { 7 }
        #expect(v == 7)
        var cancelled: Bool?
        for await c in sleeperCancelled.stream { cancelled = c }
        #expect(cancelled == true, "the sleeper was cancelled, not left to run 30 s")
    }
}
