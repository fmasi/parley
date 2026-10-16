import Testing
import Foundation
@testable import TranscriberCore

/// L round 6, item 19: the permission repair check runs one at a time. A caller that arrives while a
/// check is running must not answer at once ("not presented") while that check is about to open the
/// window: it queues a re-run (the most urgent trigger wins) and waits for the running check AND that
/// re-run, then answers.
@MainActor
@Suite struct CoalescingCheckTests {
    enum Trigger: Equatable { case recordStart, captureEvidence, userRequest }

    /// A check the test releases by hand.
    final class Gate {
        var performed: [Trigger] = []
        var waiters: [CheckedContinuation<Void, Never>] = []
        func releaseNext() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
    }

    private func makeCheck(_ gate: Gate) -> CoalescingCheck<Trigger> {
        CoalescingCheck(perform: { trigger in
            gate.performed.append(trigger)
            await withCheckedContinuation { gate.waiters.append($0) }
        }, merge: { pending, incoming in pending == .captureEvidence ? .captureEvidence : incoming })
    }

    @Test func aJoiningCallerWaitsForTheRunningCheckAndItsRerun() async {
        let gate = Gate()
        let check = makeCheck(gate)
        let first = Task { await check.run(.recordStart) }
        while gate.waiters.isEmpty { await Task.yield() }

        var joinerAnswered = false
        let joiner = Task { await check.run(.captureEvidence); joinerAnswered = true }
        for _ in 0..<20 { await Task.yield() }
        #expect(!joinerAnswered, "must not answer while the running check may still open the window")

        gate.releaseNext()                              // the running check ends…
        while gate.waiters.isEmpty { await Task.yield() }
        #expect(gate.performed == [.recordStart, .captureEvidence], "…and the joiner's re-run starts")
        #expect(!joinerAnswered, "still waiting for its own re-run")

        gate.releaseNext()
        await joiner.value
        await first.value
        #expect(joinerAnswered)
        #expect(gate.performed == [.recordStart, .captureEvidence], "one re-run, not one per caller")
    }

    @Test func theMostUrgentQueuedTriggerWins() async {
        let gate = Gate()
        let check = makeCheck(gate)
        let first = Task { await check.run(.recordStart) }
        while gate.waiters.isEmpty { await Task.yield() }
        let a = Task { await check.run(.captureEvidence) }
        let b = Task { await check.run(.userRequest) }
        for _ in 0..<20 { await Task.yield() }
        gate.releaseNext()
        while gate.waiters.isEmpty { await Task.yield() }
        gate.releaseNext()
        await a.value; await b.value; await first.value
        #expect(gate.performed == [.recordStart, .captureEvidence])
    }

    @Test func anIdleCheckRunsAtOnce() async {
        let gate = Gate()
        let check = makeCheck(gate)
        let only = Task { await check.run(.userRequest) }
        while gate.waiters.isEmpty { await Task.yield() }
        gate.releaseNext()
        await only.value
        #expect(gate.performed == [.userRequest])
    }
}
