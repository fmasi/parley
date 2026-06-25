import Testing
@testable import TranscriberCore

struct RestartDecisionTests {
    @Test func userStoppedIsIgnored() {
        #expect(RestartDecision.evaluate(isUserStopped: true, isCapturing: true, attempts: 0, maxAttempts: 3) == .ignore)
    }

    @Test func notCapturingIsIgnored() {
        #expect(RestartDecision.evaluate(isUserStopped: false, isCapturing: false, attempts: 0, maxAttempts: 3) == .ignore)
    }

    @Test func transientStopRestarts() {
        #expect(RestartDecision.evaluate(isUserStopped: false, isCapturing: true, attempts: 0, maxAttempts: 3) == .restart)
    }

    @Test func lastAllowedAttemptStillRestarts() {
        #expect(RestartDecision.evaluate(isUserStopped: false, isCapturing: true, attempts: 2, maxAttempts: 3) == .restart)
    }

    @Test func atBudgetFailsFatal() {
        #expect(RestartDecision.evaluate(isUserStopped: false, isCapturing: true, attempts: 3, maxAttempts: 3) == .failFatal)
    }

    @Test func userStopWinsOverExhaustedBudget() {
        // An explicit stop is never a fatal failure, even past the restart budget.
        #expect(RestartDecision.evaluate(isUserStopped: true, isCapturing: true, attempts: 9, maxAttempts: 3) == .ignore)
    }
}
