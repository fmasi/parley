import Testing
@testable import TranscriberCore

/// H review round 1 (A): the healer's timers and tokens, on virtual time. `endSession()` (stop) and
/// `cancelAll()` (sleep) must truly stop it — no rung, no deadline, no callback — or a stopped session
/// raises a false sticky alarm into the next recording. Round 2: a verdict while asleep is an
/// implicit wake (a lost wake must not silence the tap); a verdict after a stop is not.
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
        var rungEvents = 0, givenUpEvents = 0
        /// Each `tapRecoveryRung` event's `trigger` (#317), in order.
        var rungTriggers: [String?] = []
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
        healer.onEvent = { kind, _, detail in
            if kind == .tapRecoveryRung { calls.rungEvents += 1; calls.rungTriggers.append(detail["trigger"]) }
            if kind == .tapRecoveryGivenUp { calls.givenUpEvents += 1 }
        }
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
        r.healer.endSession()                  // stop
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
        r.healer.endSession()
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
        r.healer.endSession()
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

    // MARK: - Round 2

    /// A successful slow retry clears the "a rebuild threw" flag: the give-up after it says
    /// "not delivering", never a stale "could not restart".
    @Test func aSuccessfulRetryAfterAGiveUpClearsTheRebuildFailedFlag() {
        let r = rig()
        exhaust(r)
        #expect(r.calls.giveUps == [true])
        r.clock.advance(by: 60.01)            // the slow retry runs…
        #expect(r.tap.rebuilds.count == 5)
        let retry = r.tap.rebuilds[4]         // …and succeeds, but no heartbeat follows
        r.healer.rebuildResult(rung: retry.rung, token: retry.token, succeeded: true)
        r.clock.advance(by: 3.5)
        #expect(r.calls.giveUps == [true, false])
    }

    /// A failure for a token no longer in flight is not this episode's failure.
    @Test func aStaleFailedResultDoesNotSetTheRebuildFailedFlag() {
        let r = rig()
        r.healer.trigger(.neverDelivered)
        r.clock.advance(by: 0)
        let stale = r.tap.rebuilds[0].token
        r.healer.gateClosed()                 // the gate closes over a dead tap…
        r.healer.trigger(.neverDelivered)     // …reopens: one last-chance tap rung
        r.clock.advance(by: 0)
        r.healer.gateClosed()                 // closes again before its verdict: the next reopen gives up
        r.healer.rebuildResult(rung: .rebuildAggregate, token: stale, succeeded: false)
        r.healer.trigger(.neverDelivered)
        #expect(r.calls.giveUps == [false])
    }

    /// Monitors are paused during sleep and only armed monitors give verdicts, so a stall while the
    /// healer sleeps proves the wake message was lost: heal, don't drop it.
    @Test func aVerdictAfterAMissedWakeIsHealed() {
        let r = rig()
        r.healer.cancelAll()                  // sleep; the wake never arrives
        r.healer.trigger(.stalled)
        r.clock.advance(by: 0)
        #expect(r.tap.rebuilds.count == 1)
        #expect(r.tap.rebuilds.last?.rung == .rebuildAggregate, "a fresh episode")
    }

    // MARK: - H2 council (B-M1): a coreaudiod restart or a grant between sleep and wake

    /// `srst` arrives while the healer is suspended for sleep: dropping it left the tap's objects (and
    /// its listeners, `srst` included) dead until a liveness episode escalated to a tap rung. It runs on
    /// the wake — or on the pause's expiry, which wakes the healer the same way.
    @Test func aServiceRestartWhileAsleepRunsOnWake() {
        let r = rig()
        r.healer.cancelAll()                  // sleep
        r.healer.trigger(.serviceRestarted)
        r.clock.advance(by: 1)
        #expect(r.tap.rebuilds.isEmpty, "nothing runs while asleep")
        r.healer.trigger(.wake)
        r.clock.advance(by: 0)
        #expect(r.tap.rebuilds.count == 1)
        #expect(r.tap.rebuilds.last?.rung == .rebuildTap, "the top rung: every old object id is dead")
    }

    @Test func aPermissionGrantWhileAsleepRunsOnWake() {
        let r = rig()
        r.healer.cancelAll()
        r.healer.trigger(.permissionGrant)
        r.clock.advance(by: 1)
        #expect(r.tap.rebuilds.isEmpty)
        r.healer.trigger(.wake)
        r.clock.advance(by: 0)
        #expect(r.tap.rebuilds.map(\.rung) == [.rebuildAggregate])
    }

    /// Both pending: the service restart's new tap covers the grant too.
    @Test func aRestartAndAGrantWhileAsleepRunOneTapRung() {
        let r = rig()
        r.healer.cancelAll()
        r.healer.trigger(.serviceRestarted)
        r.healer.trigger(.permissionGrant)
        r.healer.trigger(.wake)
        r.clock.advance(by: 0)
        #expect(r.tap.rebuilds.map(\.rung) == [.rebuildTap])
    }

    @Test func aVerdictAfterAMissedWakeAlsoRunsThePendingRestart() {
        let r = rig()
        r.healer.cancelAll()
        r.healer.trigger(.serviceRestarted)
        r.healer.trigger(.stalled)            // the wake was lost
        r.clock.advance(by: 0)
        #expect(r.tap.rebuilds.map(\.rung) == [.rebuildTap])
    }

    @Test func aPendingRestartDoesNotOutliveTheSession() {
        let r = rig()
        r.healer.cancelAll()
        r.healer.trigger(.serviceRestarted)
        r.healer.endSession()
        r.healer.startSession(tap: r.tap)
        r.healer.trigger(.wake)
        r.clock.advance(by: 5)
        #expect(r.tap.rebuilds.isEmpty, "a stopped session's restart never reaches the next one")
    }

    // MARK: - #235: a grant parked behind a rung in flight, then sleep

    /// A rung is in flight, the grant arrives and is parked behind it, and the Mac sleeps before the rung
    /// returns. Sleep resets the ladder; the parked grant must not go with it, or nothing rebuilds the tap
    /// under the new permission and the other side keeps recording as silence.
    private func sleepWithAGrantParked() -> Rig {
        let r = rig()
        r.healer.trigger(.stalled)
        r.clock.advance(by: 0)                // the rung is in flight
        r.healer.trigger(.permissionGrant)    // parked behind it
        r.healer.cancelAll()                  // sleep
        return r
    }

    @Test func aGrantParkedBehindARungSurvivesSleepAndRunsOnWake() {
        let r = sleepWithAGrantParked()
        r.healer.rebuildResult(rung: .rebuildAggregate, token: 1, succeeded: true)   // the rung returns while asleep
        r.clock.advance(by: 120)
        #expect(r.tap.rebuilds.count == 1, "nothing runs while asleep")
        r.healer.trigger(.wake)
        r.clock.advance(by: 0)
        #expect(r.tap.rebuilds.map(\.rung) == [.rebuildAggregate, .rebuildAggregate], "the grant's rebuild runs on the wake")
    }

    /// coreaudiod restarts while asleep: its new tap is built under the new permission, so one tap rung
    /// covers the parked grant too — whichever way sleep was announced last.
    @Test func aServiceRestartWhileAsleepCoversAParkedGrant() {
        let r = sleepWithAGrantParked()
        r.healer.trigger(.serviceRestarted)
        r.healer.cancelAll()                  // sleep announced a second time (the app and IOKit both say it)
        r.clock.advance(by: 1)
        #expect(r.tap.rebuilds.count == 1, "nothing runs while asleep")
        r.healer.trigger(.wake)
        r.clock.advance(by: 0)
        #expect(r.tap.rebuilds.map(\.rung) == [.rebuildAggregate, .rebuildTap])
    }

    @Test func aParkedGrantRunsOnceHoweverManyWakes() {
        let r = sleepWithAGrantParked()
        r.healer.trigger(.wake)
        r.clock.advance(by: 0)
        r.healer.trigger(.wake)
        r.clock.advance(by: 120)
        #expect(r.tap.rebuilds.count == 2, "one rebuild for the grant, none for the second wake")
    }

    /// No grant parked: sleep and wake rebuild nothing, as before.
    @Test func sleepWithNoGrantParkedRebuildsNothingOnWake() {
        let r = rig()
        r.healer.trigger(.stalled)
        r.clock.advance(by: 0)
        r.healer.cancelAll()
        r.healer.trigger(.wake)
        r.clock.advance(by: 120)
        #expect(r.tap.rebuilds.count == 1, "the wake never rebuilds blind")
    }

    // MARK: - #295 item 3: a grant is owed until its rebuild is dispatched

    /// The grant that arrived while asleep is queued by the wake, and the Mac sleeps again before that rebuild is
    /// dispatched. The second sleep must not drop it: it runs at the next wake.
    @Test func aGrantQueuedAtWakeSurvivesAnImmediateResleep() {
        let r = rig()
        r.healer.cancelAll()
        r.healer.trigger(.permissionGrant)
        r.healer.trigger(.wake)               // queues the grant's rebuild …
        r.healer.cancelAll()                  // … and sleep lands before it is dispatched
        r.clock.advance(by: 120)
        #expect(r.tap.rebuilds.isEmpty, "nothing runs while asleep")
        r.healer.trigger(.wake)
        r.clock.advance(by: 0)
        #expect(r.tap.rebuilds.map(\.rung) == [.rebuildAggregate], "the grant's rebuild runs at the next wake")
        r.healer.trigger(.wake)
        r.clock.advance(by: 120)
        #expect(r.tap.rebuilds.count == 1, "once, however many wakes")
    }

    /// The same while awake: the grant's rebuild is scheduled, and sleep comes before it runs.
    @Test func aGrantNotYetDispatchedWhenSleepComesRunsAtTheWake() {
        let r = rig()
        r.healer.trigger(.permissionGrant)
        r.healer.cancelAll()
        r.clock.advance(by: 1)
        #expect(r.tap.rebuilds.isEmpty)
        r.healer.trigger(.wake)
        r.clock.advance(by: 0)
        #expect(r.tap.rebuilds.map(\.rung) == [.rebuildAggregate])
    }

    /// A coreaudiod restart is kept for the wake on the same terms: its listeners are dead until the tap is rebuilt.
    @Test func aRestartQueuedAtWakeSurvivesAnImmediateResleep() {
        let r = rig()
        r.healer.cancelAll()
        r.healer.trigger(.serviceRestarted)
        r.healer.trigger(.wake)
        r.healer.cancelAll()
        r.clock.advance(by: 1)
        #expect(r.tap.rebuilds.isEmpty)
        r.healer.trigger(.wake)
        r.clock.advance(by: 0)
        #expect(r.tap.rebuilds.map(\.rung) == [.rebuildTap])
    }

    /// Once dispatched, the grant is paid: a sleep after it owes nothing, and the wake rebuilds nothing blind.
    @Test func aDispatchedGrantIsNotRunAgainAfterSleep() {
        let r = rig()
        r.healer.trigger(.permissionGrant)
        r.clock.advance(by: 0)                // dispatched
        r.healer.cancelAll()
        r.healer.trigger(.wake)
        r.clock.advance(by: 120)
        #expect(r.tap.rebuilds.map(\.rung) == [.rebuildAggregate])
    }

    /// A pending stall rung (not a grant or a restart) is not carried across a sleep: the wake never rebuilds blind.
    @Test func aPendingStallRungIsNotCarriedAcrossSleep() {
        let r = rig()
        r.healer.trigger(.stalled)
        r.healer.cancelAll()                  // before the rung is dispatched
        r.healer.trigger(.wake)
        r.clock.advance(by: 120)
        #expect(r.tap.rebuilds.isEmpty)
    }

    // MARK: - Final review H-I1: nothing expected at the deadline

    /// Recording started before the call; the grant rebuilds the tap while nothing plays. The rung's
    /// heartbeat window passes with the gate closed: no climb, no give-up, no alarm, nothing left queued
    /// — the re-armed monitor judges the tap once the call starts.
    @Test func aGrantWhileNothingPlaysNeverGivesUp() {
        let r = rig()
        r.healer.gateOpen = { false }
        r.healer.trigger(.permissionGrant)
        r.clock.advance(by: 0)
        #expect(r.tap.rebuilds.count == 1)
        #expect(r.tap.rebuilds.first?.rung == .rebuildAggregate && r.tap.rebuilds.first?.token == 1)
        r.healer.rebuildResult(rung: .rebuildAggregate, token: 1, succeeded: true)
        r.clock.advance(by: 3.1)
        r.clock.advance(by: 120)
        #expect(r.calls.giveUps.isEmpty && r.calls.givenUpEvents == 0)
        #expect(r.tap.rebuilds.count == 1, "the deadline climbed nothing")
        #expect(r.clock.pending == 0, "no rung, deadline or slow retry left")
        r.healer.gateOpen = { true }
        r.healer.heartbeatObserved()          // the call starts and the rebuilt tap is heard
        #expect(r.calls.recovered == 0, "nothing was healing")
    }

    /// A stale deadline — its rung replaced by a coreaudiod restart that did not cancel the timer —
    /// firing with the gate closed must not drop the CURRENT episode's work: the rung the restart's
    /// failure queued still runs (a cancelled rung left in flight would wedge the ladder).
    @Test func aStaleDeadlineWithTheGateClosedLeavesTheNextRungAlone() {
        let r = rig()
        r.healer.trigger(.neverDelivered)
        answerNextRung(r, succeeded: true)    // token 1 awaits its heartbeat; its deadline is 3 s out
        r.clock.advance(by: 2.9)
        r.healer.trigger(.serviceRestarted)   // token 2 at once; token 1's deadline timer stays armed
        r.clock.advance(by: 0)
        r.healer.rebuildResult(rung: .rebuildTap, token: 2, succeeded: false)   // token 3 waits out 0.25 s
        r.healer.gateOpen = { false }
        r.clock.advance(by: 0.5)              // token 1's stale deadline fires first, then token 3 is due
        #expect(r.tap.rebuilds.map(\.token) == [1, 2, 3], "the stale deadline cancelled nothing")
    }

    // MARK: - Final review HF-9: a give-up at idle never claims audio is playing

    /// Rebuilds that threw while nothing plays (an `srst` at pre-call idle, coreaudiod still coming up):
    /// "could not restart" is true and is raised; "isn't reaching Parley although audio is playing" is
    /// not — and nothing at idle would clear it. With audio playing, both as before; a give-up with nothing
    /// thrown always says not-delivering, whatever the gate (never silent).
    @Test func aGiveUpFromThrowingRebuildsWhileNothingPlaysNeverSaysNotDelivering() {
        #expect(TapHealer.giveUpAlarms(rebuildFailed: true, gateOpen: false) == [.remoteRecoveryFailed])
        #expect(TapHealer.giveUpAlarms(rebuildFailed: true, gateOpen: true) == [.remoteNotDelivering, .remoteRecoveryFailed])
        #expect(TapHealer.giveUpAlarms(rebuildFailed: false, gateOpen: true) == [.remoteNotDelivering])
        #expect(TapHealer.giveUpAlarms(rebuildFailed: false, gateOpen: false) == [.remoteNotDelivering], "never silent")
    }

    @Test func aVerdictAfterAStopIsStillIgnored() {
        let r = rig()
        r.healer.endSession()
        r.healer.trigger(.stalled)
        r.healer.heartbeatObserved()
        r.clock.advance(by: 10)
        #expect(r.tap.rebuilds.isEmpty)
        #expect(r.clock.pending == 0)
    }

    // MARK: - #317: the rung's record names its trigger

    /// The insurance rebuild 12 s into a call whose remote had not spoken yet showed as a bare `tapRecoveryRung`.
    @Test func theRungEventNamesThePermissionInsuranceThatOrderedIt() {
        let r = rig()
        r.healer.trigger(.permissionInsurance)
        r.clock.advance(by: 0)
        #expect(r.tap.rebuilds.count == 1)
        #expect(r.calls.rungTriggers == ["permissionInsurance"])
    }

    @Test func theRungEventNamesEachTriggerInTurn() {
        let r = rig()
        r.healer.trigger(.neverDelivered)
        answerNextRung(r, succeeded: false)
        answerNextRung(r, succeeded: true)
        r.clock.advance(by: TapRecoveryLadder.heartbeatDeadlineSeconds + 1)   // no heartbeat: the next rung
        #expect(r.calls.rungTriggers.prefix(3) == ["neverDelivered", "rebuildFailed", "heartbeatMissed"])
    }
}
