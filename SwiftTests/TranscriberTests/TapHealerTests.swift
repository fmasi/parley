import Testing
@testable import TranscriberCore

/// H review round 1 (A): the healer's timers and tokens, on virtual time. `cancelAll()` (stop,
/// sleep) must truly stop it — no rung, no deadline, no callback — or a stopped session raises a
/// false sticky alarm into the next recording.
@Suite struct TapHealerTests {
    /// Virtual time: `async` runs inline (the tests ARE the serial context), `after` waits for `advance`.
    final class ManualScheduler: HealerScheduler {
        private(set) var now: Double = 0
        private final class Item: HealerTimer {
            let at: Double, seq: Int
            var work: (() -> Void)?
            init(at: Double, seq: Int, work: @escaping () -> Void) { self.at = at; self.seq = seq; self.work = work }
            func cancel() { work = nil }
        }
        private var items: [Item] = []
        private var seq = 0

        func async(_ work: @escaping () -> Void) { work() }
        func after(_ seconds: Double, _ work: @escaping () -> Void) -> HealerTimer {
            seq += 1
            let item = Item(at: now + seconds, seq: seq, work: work)
            items.append(item)
            return item
        }
        /// Timers neither fired nor cancelled.
        var pending: Int { items.filter { $0.work != nil }.count }
        func advance(by seconds: Double) {
            let end = now + seconds
            while let next = items.filter({ $0.work != nil && $0.at <= end }).min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) {
                now = next.at
                let work = next.work
                next.work = nil
                work?()
            }
            now = end
        }
    }

    final class FakeTap: TapRebuilding {
        var rebuilds: [(rung: TapRecoveryLadder.Rung, token: Int)] = []
        func rebuild(rung: TapRecoveryLadder.Rung, token: Int, reason: String) { rebuilds.append((rung, token)) }
    }

    final class Calls {
        var giveUps: [Bool] = []
        var recovered = 0, stuck = 0, succeeded = 0
        var rungEvents = 0
    }

    /// Keeps the fake tap alive (the healer holds it weakly).
    struct Rig {
        let healer: TapHealer
        let clock: ManualScheduler
        let tap: FakeTap
        let calls: Calls
    }

    private func rig() -> Rig {
        let clock = ManualScheduler(), tap = FakeTap(), calls = Calls()
        let healer = TapHealer(scheduler: clock)
        healer.onGiveUp = { calls.giveUps.append($0) }
        healer.onRecovered = { calls.recovered += 1 }
        healer.onStuck = { calls.stuck += 1 }
        healer.onRungSucceeded = { calls.succeeded += 1 }
        healer.onEvent = { kind, _, _ in if kind == .tapRecoveryRung { calls.rungEvents += 1 } }
        healer.startSession(tap: tap)
        return Rig(healer: healer, clock: clock, tap: tap, calls: calls)
    }

    /// Advances until the tap is asked for the next rung, then answers it.
    private func answerNextRung(_ r: Rig, succeeded: Bool) {
        let before = r.tap.rebuilds.count
        var waited = 0.0
        while r.tap.rebuilds.count == before, waited < 10 { r.clock.advance(by: 0.25); waited += 0.25 }
        guard let last = r.tap.rebuilds.last, r.tap.rebuilds.count > before else { Issue.record("no rung ran"); return }
        r.healer.rebuildResult(rung: last.rung, token: last.token, succeeded: succeeded)
    }

    /// Four failed rungs: the fast budget is gone and the ladder gives up.
    private func exhaust(_ r: Rig) {
        r.healer.trigger(.neverDelivered)
        for _ in 0..<4 { answerNextRung(r, succeeded: false) }
    }

    // MARK: - cancelAll stops everything

    @Test func stopMidHealLeavesNoRungNoDeadlineAndNoAlarm() {
        let r = rig()
        r.healer.trigger(.neverDelivered)
        answerNextRung(r, succeeded: false)   // the next rung is now waiting out its backoff
        #expect(r.tap.rebuilds.count == 1)
        r.healer.cancelAll()                  // stop
        #expect(r.clock.pending == 0)
        r.healer.rebuildResult(rung: .rebuildAggregate, token: 2, succeeded: true)   // late, from the stopped session
        r.healer.trigger(.stalled)
        r.clock.advance(by: 120)
        #expect(r.tap.rebuilds.count == 1, "no rung after the stop")
        #expect(r.calls.giveUps.isEmpty && r.calls.stuck == 0 && r.calls.succeeded == 0, "no callback after the stop")
        #expect(r.clock.pending == 0, "no deadline, watchdog or retry left")
    }

    @Test func sleepMidHealThenWakeStartsAFreshEpisode() {
        let r = rig()
        exhaust(r)
        #expect(r.calls.giveUps.count == 1)
        r.healer.cancelAll()                  // sleep
        r.clock.advance(by: 120)
        #expect(r.tap.rebuilds.count == 4, "the slow retry does not run while asleep")
        r.healer.trigger(.wake)
        r.healer.trigger(.stalled)            // an exhausted ladder would ignore this
        r.clock.advance(by: 0)
        #expect(r.tap.rebuilds.count == 5)
        #expect(r.tap.rebuilds.last?.rung == .rebuildAggregate, "a fresh episode starts at the first rung")
    }

    @Test func aStaleResultWhileStoppedCompletesNothing() {
        let r = rig()
        r.healer.trigger(.neverDelivered)
        r.clock.advance(by: 0)
        let token = r.tap.rebuilds[0].token
        r.healer.cancelAll()
        r.healer.rebuildResult(rung: .rebuildAggregate, token: token, succeeded: true)
        #expect(r.calls.succeeded == 0)
        #expect(r.clock.pending == 0, "no heartbeat deadline armed by a stale result")
    }

    @Test func aResultFromBeforeAWakeCompletesNothing() {
        let r = rig()
        r.healer.trigger(.neverDelivered)
        r.clock.advance(by: 0)
        let old = r.tap.rebuilds[0].token
        r.healer.cancelAll()
        r.healer.trigger(.wake)
        r.healer.trigger(.neverDelivered)
        r.clock.advance(by: 0)
        #expect(r.tap.rebuilds.count == 2)
        r.healer.rebuildResult(rung: .rebuildAggregate, token: old, succeeded: true)
        r.clock.advance(by: 4)                // a completed rung would have missed its 3 s deadline by now
        #expect(r.tap.rebuilds.count == 2, "the current rung is still in flight")
        r.clock.advance(by: 2)
        #expect(r.calls.stuck == 1, "and its stuck watchdog still runs")
    }

    /// A rung scheduled for one session never rebuilds the next session's tap (ruling A4).
    @Test func aRungFromTheLastSessionNeverRebuildsTheNextTap() {
        let r = rig()
        r.healer.trigger(.neverDelivered)
        answerNextRung(r, succeeded: false)   // next rung waiting out its backoff
        r.healer.cancelAll()
        let next = FakeTap()
        r.healer.startSession(tap: next)
        r.clock.advance(by: 5)
        #expect(next.rebuilds.isEmpty)
    }

    // MARK: - Timers

    @Test func giveUpKeepsAPendingSlowRetry() {
        let r = rig()
        exhaust(r)                            // gives up; slow retry due 60 s later
        let gaveUpAt = r.clock.now
        r.clock.advance(by: 30)
        r.healer.trigger(.permissionGrant)    // a grant rung on the exhausted ladder…
        answerNextRung(r, succeeded: false)   // …fails: the ladder gives up again
        #expect(r.calls.giveUps.count == 2)
        #expect(r.clock.pending == 1, "only the original slow retry")
        r.clock.advance(by: gaveUpAt + 60 - r.clock.now + 0.001)
        #expect(r.tap.rebuilds.last?.rung == .rebuildTap, "the retry runs on its original schedule")
        #expect(r.tap.rebuilds.count == 6)
    }

    @Test func aStaleResultCannotCancelTheCurrentStuckWatchdog() {
        let r = rig()
        r.healer.trigger(.neverDelivered)
        r.clock.advance(by: 0)
        let first = r.tap.rebuilds[0].token
        r.healer.heartbeatObserved()          // the ladder forgets that rung
        r.healer.trigger(.stalled)
        r.clock.advance(by: 1)                // the next rung runs after its backoff
        #expect(r.tap.rebuilds.count == 2)
        r.healer.rebuildResult(rung: .rebuildAggregate, token: first, succeeded: true)
        r.clock.advance(by: 5)
        #expect(r.calls.stuck == 1)
    }

    @Test func oneHeartbeatDeadlineAtATime() {
        let r = rig()
        r.healer.trigger(.neverDelivered)
        answerNextRung(r, succeeded: true)    // awaiting a heartbeat
        #expect(r.clock.pending == 1)
        r.healer.trigger(.permissionGrant)    // a grant rung replaces the wait
        answerNextRung(r, succeeded: true)
        #expect(r.clock.pending == 1, "the new deadline replaced the old one")
    }

    // MARK: - Heal first, then alarm

    @Test func anIntermediateFailedRungDoesNotGiveUp() {
        let r = rig()
        r.healer.trigger(.neverDelivered)
        answerNextRung(r, succeeded: false)
        answerNextRung(r, succeeded: true)
        r.healer.heartbeatObserved()
        #expect(r.calls.giveUps.isEmpty)
        #expect(r.calls.recovered == 1)
    }

    @Test func giveUpSaysWhetherARebuildFailed() {
        let failing = rig()
        exhaust(failing)
        #expect(failing.calls.giveUps == [true])

        let silent = rig()                    // every rung succeeds, no heartbeat ever comes
        silent.healer.trigger(.neverDelivered)
        for _ in 0..<4 { answerNextRung(silent, succeeded: true) }
        silent.clock.advance(by: 3)
        #expect(silent.calls.giveUps == [false])
    }

    @Test func theRungEventIsRecordedWhenTheRungRunsNotWhenScheduled() {
        let r = rig()
        r.healer.trigger(.neverDelivered)
        answerNextRung(r, succeeded: false)   // rung 1 ran; rung 2 is waiting out its backoff
        #expect(r.calls.rungEvents == 1)
        r.healer.heartbeatObserved()          // the tap came back before rung 2 ran
        r.clock.advance(by: 2)
        #expect(r.tap.rebuilds.count == 1)
        #expect(r.calls.rungEvents == 1)
    }
}
