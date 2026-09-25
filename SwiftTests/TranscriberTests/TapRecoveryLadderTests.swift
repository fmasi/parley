import Testing
@testable import TranscriberCore

/// §5: a silent tap is rebuilt — aggregate first, then the whole tap — with backoff and a budget,
/// then alarmed, then retried slowly. Incident B had the rebuild code; nothing ever triggered it,
/// and one thrown rebuild was permanent (`onUnavailable`).
@Suite struct TapRecoveryLadderTests {
    typealias L = TapRecoveryLadder

    @Test func firstTriggerRunsAnAggregateRebuildImmediately() {
        var l = L()
        #expect(l.trigger(.stalled, now: 0) == .run(.rebuildAggregate, token: 1, afterSeconds: 0))
        #expect(l.inFlight == .rebuildAggregate && l.inFlightToken == 1)
    }

    /// Review focus 4: an aggregate listener and a monitor verdict describe the same stall.
    @Test func secondTriggerWhileARungIsInFlightIsIgnored() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.trigger(.listenerStopped, now: 0.1) == .none)
        #expect(l.trigger(.neverDelivered, now: 0.2) == .none)
        #expect(l.totalRebuilds == 1)
    }

    /// A rung scheduled after a backoff is in flight from the moment it is ordered, not from the
    /// moment it runs: a second trigger inside the backoff window must not order a second rebuild.
    @Test func aTriggerInsideTheBackoffWindowIsIgnored() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.rungCompleted(token: 1, succeeded: false, now: 0.2) == .run(.rebuildAggregate, token: 2, afterSeconds: 0.25))
        // Token 2 runs at 0.45; until then the listener, a failed external rebuild and a stale
        // deadline all describe the episode already being handled.
        #expect(l.trigger(.listenerStopped, now: 0.3) == .none)
        #expect(l.trigger(.rebuildFailed, now: 0.35) == .none)
        #expect(l.heartbeatDeadlineMissed(token: 1, now: 0.4, gateOpen: true) == .none)
        #expect(l.inFlightToken == 2 && l.totalRebuilds == 2)
    }

    @Test func aSuccessfulRungWaitsForAHeartbeat() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.rungCompleted(token: 1, succeeded: true, now: 0.4) == .awaitHeartbeat(seconds: L.heartbeatDeadlineSeconds, token: 1))
        #expect(l.trigger(.stalled, now: 1) == .none, "already waiting; a verdict must not start a second rebuild")
    }

    @Test func aHeartbeatClosesTheEpisode() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.4)
        #expect(l.heartbeatObserved(now: 0.5) == .none)
        #expect(l.inFlight == nil && !l.awaitingHeartbeat && !l.exhausted)
        #expect(l.trigger(.stalled, now: 100) == .run(.rebuildAggregate, token: 2, afterSeconds: 0), "a separate stall after the heal held starts a fresh episode")
    }

    @Test func missedHeartbeatBacksOffThenEscalatesToTheTapRung() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.3)
        #expect(l.heartbeatDeadlineMissed(token: 1, now: 3.3, gateOpen: true) == .run(.rebuildAggregate, token: 2, afterSeconds: 0.25))
        _ = l.rungCompleted(token: 2, succeeded: true, now: 3.9)
        #expect(l.heartbeatDeadlineMissed(token: 2, now: 6.9, gateOpen: true) == .run(.rebuildTap, token: 3, afterSeconds: 0.5))
        _ = l.rungCompleted(token: 3, succeeded: true, now: 7.6)
        #expect(l.heartbeatDeadlineMissed(token: 3, now: 10.6, gateOpen: true) == .run(.rebuildTap, token: 4, afterSeconds: 1))
    }

    @Test func aThrownRungMovesOnAfterBackoff() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.rungCompleted(token: 1, succeeded: false, now: 0.2) == .run(.rebuildAggregate, token: 2, afterSeconds: 0.25))
    }

    private func exhaust(_ l: inout L) {
        _ = l.trigger(.stalled, now: 0)
        for _ in 0..<4 {
            let token = l.inFlightToken!
            _ = l.rungCompleted(token: token, succeeded: true, now: 1)
            _ = l.heartbeatDeadlineMissed(token: token, now: 4, gateOpen: true)
        }
    }

    @Test func budgetExhaustedGivesUpWithASlowRetry() {
        var l = L()
        exhaust(&l)
        #expect(l.exhausted)
        #expect(l.trigger(.stalled, now: 5) == .none, "exhausted: the slow retry owns it")
        #expect(l.slowRetryDue(now: 65) == .run(.rebuildTap, token: 5, afterSeconds: 0))
        #expect(l.rungCompleted(token: 5, succeeded: false, now: 66) == .giveUp(retryAfterSeconds: L.slowRetrySeconds))
        #expect(l.exhausted)
    }

    @Test func giveUpActionCarriesTheSlowRetryInterval() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        var last: L.Action = .none
        for _ in 0..<4 {
            let token = l.inFlightToken!
            _ = l.rungCompleted(token: token, succeeded: true, now: 1)
            last = l.heartbeatDeadlineMissed(token: token, now: 4, gateOpen: true)
        }
        #expect(last == .giveUp(retryAfterSeconds: L.slowRetrySeconds))
    }

    /// The slow retry is one rebuild whose heartbeat the ladder still waits for. A slow-retry timer
    /// that comes due while such a heartbeat is pending (here: the grant rung on the exhausted ladder
    /// just succeeded) must not order a second rebuild: the pending deadline decides, and its miss
    /// hands back the next slow retry.
    @Test func aSlowRetryDueWhileAHeartbeatIsPendingDoesNotStartASecondRebuild() {
        var l = L()
        exhaust(&l)
        _ = l.trigger(.permissionGrant, now: 62)                                        // token 5
        #expect(l.rungCompleted(token: 5, succeeded: true, now: 63.8) == .awaitHeartbeat(seconds: L.heartbeatDeadlineSeconds, token: 5))
        #expect(l.slowRetryDue(now: 64) == .none)
        #expect(l.heartbeatDeadlineMissed(token: 5, now: 66.8, gateOpen: true) == .giveUp(retryAfterSeconds: L.slowRetrySeconds))
        #expect(l.slowRetryDue(now: 126.8) == .run(.rebuildTap, token: 6, afterSeconds: 0))
    }

    @Test func aFastWindowTimeoutGivesUpEvenWithBudgetLeft() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.5)
        #expect(l.heartbeatDeadlineMissed(token: 1, now: 20, gateOpen: true) == .giveUp(retryAfterSeconds: L.slowRetrySeconds))
    }

    // MARK: - Fix round 1: a heal must hold before the budget comes back

    /// A heartbeat ends the silence, not the episode. The reviewer's harness: every aggregate rung
    /// brings one buffer back, then the tap dies again 3 s later. Refunding the budget on every
    /// heartbeat rebuilt the aggregate 50 times with no alarm; the ladder must climb and give up.
    @Test func aHealThatDoesNotHoldKeepsClimbingAndGivesUpWithinTheBudget() {
        var l = L()
        var t = 0.0, rungs: [L.Rung] = [], giveUps = 0
        for _ in 0..<50 {
            switch l.trigger(.stalled, now: t) {
            case .run(let rung, let token, _):
                rungs.append(rung)
                _ = l.rungCompleted(token: token, succeeded: true, now: t + 0.3)
                _ = l.heartbeatObserved(now: t + 0.5)       // the new generation's first frames
            case .giveUp:
                giveUps += 1
            default:
                break
            }
            t += 3.5                                          // one buffer, then a 3 s stall
        }
        #expect(rungs == [.rebuildAggregate, .rebuildAggregate, .rebuildTap, .rebuildTap])
        #expect(giveUps == 1 && l.exhausted && l.totalRebuilds == 4)
    }

    /// The budget comes back only after `sustainedHealthSeconds` of health: a stall 29.9 s after a
    /// heal is the same episode (next attempt, with backoff); one 30 s after is a fresh episode.
    @Test func aHealThatHoldsForThirtySecondsRefundsTheBudget() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)                                           // token 1
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.3)
        _ = l.heartbeatObserved(now: 1)
        #expect(l.trigger(.stalled, now: 30.9) == .run(.rebuildAggregate, token: 2, afterSeconds: 0.25))
        _ = l.rungCompleted(token: 2, succeeded: true, now: 31.2)
        _ = l.heartbeatObserved(now: 31.5)
        #expect(l.trigger(.stalled, now: 61.5) == .run(.rebuildAggregate, token: 3, afterSeconds: 0))
    }

    /// A heal re-opens an exhausted ladder to a later stall — but that stall continues the spent
    /// episode, so it re-alarms at once instead of being ignored (no slow retry is pending any more).
    @Test func aStallSoonAfterASlowRetryHealedReAlarms() {
        var l = L()
        exhaust(&l)
        _ = l.slowRetryDue(now: 64)                                               // token 5
        _ = l.rungCompleted(token: 5, succeeded: true, now: 64.5)
        _ = l.heartbeatObserved(now: 65)
        #expect(!l.exhausted)
        #expect(l.trigger(.stalled, now: 70) == .giveUp(retryAfterSeconds: L.slowRetrySeconds))
    }

    // MARK: - Tokens

    /// coreaudiod restart: every id is dead, nothing below a new tap can help.
    @Test func serviceRestartedJumpsStraightToANewTap() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.trigger(.serviceRestarted, now: 0.1) == .run(.rebuildTap, token: 2, afterSeconds: 0))
    }

    @Test func serviceRestartedOnAnExhaustedLadderRunsANewTapAtOnce() {
        var l = L()
        exhaust(&l)
        #expect(l.trigger(.serviceRestarted, now: 30) == .run(.rebuildTap, token: 5, afterSeconds: 0))
        #expect(!l.exhausted && l.inFlightToken == 5)
        #expect(l.slowRetryDue(now: 64) == .none, "the restart's rung owns the tap now")
    }

    /// The old rung's result arriving after a service restart must not complete the new rung.
    @Test func aStaleRungResultAfterAServiceRestartIsIgnored() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)                                   // token 1
        _ = l.trigger(.serviceRestarted, now: 0.1)                        // token 2
        #expect(l.rungCompleted(token: 1, succeeded: true, now: 0.3) == .none)
        #expect(l.inFlight == .rebuildTap && l.inFlightToken == 2)
    }

    /// Fix round 1: the heartbeat deadline is matched on the rung's token, so a deadline timer left
    /// over from a replaced rung cannot cut the newer rung's 3 s window short.
    @Test func aStaleHeartbeatDeadlineDoesNotCutANewerRungShort() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)                                            // token 1
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.3)                   // its deadline: 3.3
        _ = l.trigger(.serviceRestarted, now: 1)                                   // token 2
        #expect(l.rungCompleted(token: 2, succeeded: true, now: 1.5) == .awaitHeartbeat(seconds: L.heartbeatDeadlineSeconds, token: 2))
        #expect(l.heartbeatDeadlineMissed(token: 1, now: 3.3, gateOpen: true) == .none)
        #expect(l.awaitingHeartbeat)
        #expect(l.heartbeatDeadlineMissed(token: 2, now: 4.5, gateOpen: true) == .run(.rebuildAggregate, token: 3, afterSeconds: 0.25))
    }

    /// Review focus 4 (scan A66/C9): an output-device rebuild completing while a ladder rung is in
    /// flight is NOT the rung's result — results are matched by token — but it does count against
    /// the episode's budget (§5: "their rebuilds report into the same ladder budget").
    @Test func anOffLadderRebuildResultDoesNotCompleteTheRung() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)                                   // token 1 in flight
        #expect(l.rungCompleted(token: 0, succeeded: true, now: 0.2) == .none)
        #expect(l.inFlight == .rebuildAggregate, "still waiting for token 1")
        #expect(l.noteExternalRebuild(now: 0.2) == .none)
        #expect(l.totalRebuilds == 2)
        #expect(l.rungCompleted(token: 1, succeeded: true, now: 0.4) == .awaitHeartbeat(seconds: L.heartbeatDeadlineSeconds, token: 1))
        // The external rebuild used one of the two aggregate attempts: the next miss escalates to the tap rung.
        #expect(l.heartbeatDeadlineMissed(token: 1, now: 3.4, gateOpen: true) == .run(.rebuildTap, token: 2, afterSeconds: 0.25))
    }

    @Test func anExternalRebuildOutsideAnEpisodeCostsNoBudget() {
        var l = L()
        _ = l.noteExternalRebuild(now: 0)
        #expect(l.totalRebuilds == 1)
        _ = l.trigger(.stalled, now: 10)
        _ = l.rungCompleted(token: 1, succeeded: true, now: 10.3)
        #expect(l.heartbeatDeadlineMissed(token: 1, now: 13.3, gateOpen: true) == .run(.rebuildAggregate, token: 2, afterSeconds: 0.25), "both aggregate attempts still available")
    }

    // MARK: - The gate

    /// Spec §5 as amended in fix round 1 (the controller's ruling overrides scan C10): the gate
    /// closing cancels the episode's work and the slow retry, but a tap that was still dead is
    /// remembered. The reopen gets ONE immediate tap rung and its failure re-alarms at once, rather
    /// than a fresh four-rung episode per gate blip.
    @Test func gateClosedOverAnExhaustedLadderGivesTheReopenOneTapRung() {
        var l = L()
        exhaust(&l)
        #expect(l.gateClosed() == .none)
        #expect(!l.exhausted && l.inFlight == nil && !l.awaitingHeartbeat)
        #expect(l.slowRetryDue(now: 64) == .none, "nothing is expected: no slow retry")
        #expect(l.trigger(.neverDelivered, now: 100) == .run(.rebuildTap, token: 5, afterSeconds: 0))
        _ = l.rungCompleted(token: 5, succeeded: true, now: 100.3)
        #expect(l.heartbeatDeadlineMissed(token: 5, now: 103.3, gateOpen: true) == .giveUp(retryAfterSeconds: L.slowRetrySeconds))
    }

    /// The reviewer's harness: 10 s open / 1 s closed over a tap that never delivers. Refunding on
    /// every close ran 40 rebuilds and never alarmed; now each reopen costs one tap rung and alarms
    /// about 3 s after its trigger.
    @Test func aGateBlipOverADeadTapGetsOneTapRungPerReopenAndReAlarms() {
        let (rebuilds, giveUps) = driveGateFlapOverADeadTap(openSeconds: 10, periods: 20)
        #expect(rebuilds == 2 + 19, "the first period's two aggregate rungs, then one tap rung per reopen")
        #expect(giveUps == 19, "every reopen re-alarms")
    }

    /// A faster flap (7 s open) closes the gate before the last chance's 3 s deadline. A last chance
    /// that never got its verdict counts as failed, so the next reopen re-alarms at once instead of
    /// rebuilding silently forever: at most one rebuild and at least one alarm per two reopens.
    @Test func aFastGateFlapOverADeadTapStillReAlarms() {
        let (rebuilds, giveUps) = driveGateFlapOverADeadTap(openSeconds: 7, periods: 20)
        #expect(rebuilds == 1 + 10)
        #expect(giveUps == 9)
    }

    /// Each period: the gate opens at `t`, the monitor reports never-delivered at `t + 5`, every rung
    /// "succeeds" but no heartbeat ever comes, and the gate closes at `t + openSeconds` (then 1 s shut).
    private func driveGateFlapOverADeadTap(openSeconds: Double, periods: Int) -> (rebuilds: Int, giveUps: Int) {
        var l = L()
        var rebuilds = 0, giveUps = 0, t = 0.0
        for _ in 0..<periods {
            var now = t + 5
            var action = l.trigger(.neverDelivered, now: now)
            while true {
                if case .giveUp = action { giveUps += 1; break }
                guard case .run(_, let token, let delay) = action else { break }
                rebuilds += 1
                now += delay + 0.3
                _ = l.rungCompleted(token: token, succeeded: true, now: now)
                now += L.heartbeatDeadlineSeconds
                guard now < t + openSeconds else { break }          // the gate closes first
                action = l.heartbeatDeadlineMissed(token: token, now: now, gateOpen: true)
            }
            _ = l.gateClosed()
            t += openSeconds + 1
        }
        return (rebuilds, giveUps)
    }

    /// A gate blip over a tap that HAD healed (not yet for 30 s) is not a refund either: the next
    /// stall continues the episode.
    @Test func aGateBlipDoesNotRefundAHealThatHasNotHeld() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)                                   // aggregate, token 1
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.3)
        _ = l.heartbeatObserved(now: 0.5)
        #expect(l.gateClosed() == .none)
        #expect(l.trigger(.stalled, now: 5) == .run(.rebuildAggregate, token: 2, afterSeconds: 0.25), "its second aggregate attempt")
    }

    /// The tap coming back on its own after the reopen clears the memory: a later stall gets the
    /// full ladder.
    @Test func aHeartbeatAfterTheGateReopensForgetsTheDeadTap() {
        var l = L()
        exhaust(&l)
        _ = l.gateClosed()
        _ = l.heartbeatObserved(now: 100)
        #expect(l.trigger(.stalled, now: 200) == .run(.rebuildAggregate, token: 5, afterSeconds: 0))
    }

    @Test func aRungResultArrivingAfterTheGateClosedIsIgnored() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)                                   // token 1 in flight
        #expect(l.gateClosed() == .none)
        #expect(l.inFlight == nil && !l.awaitingHeartbeat)
        #expect(l.rungCompleted(token: 1, succeeded: true, now: 0.4) == .none)
        #expect(!l.awaitingHeartbeat)
    }

    // MARK: - Final review H-I1: a deadline that passes while nothing is expected

    /// Recording started before the call (N-06), and a rung ran while nothing plays: a permission grant,
    /// a coreaudiod restart or the insurance rebuild. Its 3 s heartbeat window cannot judge a tap nobody
    /// expects to hear, so the deadline ends the episode as a gate close does — the silent tap is
    /// remembered — and never climbs to a false alarm. When the call starts, the re-armed monitor's
    /// never-delivered verdict gets the reopen's ONE tap rung, then the alarm: never a fresh four-rung
    /// episode, never silence.
    @Test(arguments: zip([TapRecoveryLadder.Trigger.permissionGrant, .serviceRestarted, .permissionInsurance],
                         [TapRecoveryLadder.Rung.rebuildAggregate, .rebuildTap, .rebuildAggregate]))
    func aGrantRungWhoseDeadlinePassesWithTheGateClosedDoesNotClimb(_ trigger: TapRecoveryLadder.Trigger,
                                                                    _ rung: TapRecoveryLadder.Rung) {
        var l = L()
        #expect(l.trigger(trigger, now: 0) == .run(rung, token: 1, afterSeconds: 0))
        #expect(l.rungCompleted(token: 1, succeeded: true, now: 0.1) == .awaitHeartbeat(seconds: L.heartbeatDeadlineSeconds, token: 1))
        #expect(l.heartbeatDeadlineMissed(token: 1, now: 3.1, gateOpen: false) == .none)
        #expect(l.inFlight == nil && !l.awaitingHeartbeat && !l.exhausted)
        #expect(l.totalRebuilds == 1, "nothing climbed")
        // The call starts ten minutes later and the tap still delivers nothing.
        #expect(l.trigger(.neverDelivered, now: 600) == .run(.rebuildTap, token: 2, afterSeconds: 0), "the reopen's last chance, not a fresh aggregate")
        #expect(l.rungCompleted(token: 2, succeeded: true, now: 600.3) == .awaitHeartbeat(seconds: L.heartbeatDeadlineSeconds, token: 2))
        #expect(l.heartbeatDeadlineMissed(token: 2, now: 603.3, gateOpen: true) == .giveUp(retryAfterSeconds: L.slowRetrySeconds))
    }

    /// The default path: with the track expected at the deadline, a missed heartbeat still climbs.
    @Test func aStallRungWhoseDeadlinePassesWithTheGateOpenStillClimbs() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.3)
        #expect(l.heartbeatDeadlineMissed(token: 1, now: 3.3, gateOpen: true) == .run(.rebuildAggregate, token: 2, afterSeconds: 0.25))
    }

    /// Only the awaited rung's deadline is judged: a stale one with the gate closed ends nothing — the
    /// rung that replaced it stays in flight.
    @Test func aStaleDeadlineWithTheGateClosedEndsNothing() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)                                            // token 1
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.3)
        _ = l.trigger(.serviceRestarted, now: 1)                                   // token 2
        #expect(l.heartbeatDeadlineMissed(token: 1, now: 3.3, gateOpen: false) == .none)
        #expect(l.inFlight == .rebuildTap && l.inFlightToken == 2)
    }

    // MARK: - Wake (§5, §8.8: re-arm + heartbeat check, never a blind rebuild)

    /// Fix round 1: the helper cancels its timers on sleep, so an exhausted ladder that ignored
    /// `.wake` stayed exhausted with no slow retry left to fire. The re-armed monitor is the check.
    @Test func wakeOnAnExhaustedLadderResetsItWithoutRebuilding() {
        var l = L()
        exhaust(&l)
        #expect(l.trigger(.wake, now: 500) == .none)
        #expect(!l.exhausted && l.totalRebuilds == 4)
        #expect(l.trigger(.stalled, now: 505) == .run(.rebuildAggregate, token: 5, afterSeconds: 0))
    }

    @Test func wakeWhileAwaitingAHeartbeatResetsItWithoutRebuilding() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.3)
        #expect(l.trigger(.wake, now: 500) == .none)
        #expect(!l.awaitingHeartbeat)
        #expect(l.heartbeatDeadlineMissed(token: 1, now: 503, gateOpen: true) == .none, "the pre-sleep deadline is gone")
        #expect(l.trigger(.stalled, now: 505) == .run(.rebuildAggregate, token: 2, afterSeconds: 0))
    }

    @Test func wakeOnAQuietLadderNeverRebuildsBlind() {
        var l = L()
        #expect(l.trigger(.wake, now: 0) == .none)
        #expect(l.totalRebuilds == 0)
        #expect(l.trigger(.stalled, now: 5) == .run(.rebuildAggregate, token: 1, afterSeconds: 0))
    }

    // MARK: - Permission

    /// A grant reaches only a tap built after it: never refused, never delayed, even when exhausted.
    @Test func permissionGrantRunsEvenWhenExhausted() {
        var l = L()
        exhaust(&l)
        #expect(l.trigger(.permissionGrant, now: 5) == .run(.rebuildAggregate, token: 5, afterSeconds: 0))
    }

    /// A grant while a rung is in flight is dropped, not queued: that rung builds its aggregate after
    /// the grant, or, if it was already past that point, `TapPermissionGuard.tapBuilt(status:)` marks
    /// the tap as built without the grant and the guard asks again.
    @Test func permissionGrantWhileARungIsInFlightIsDropped() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.trigger(.permissionGrant, now: 0.1) == .none)
        #expect(l.inFlightToken == 1 && l.totalRebuilds == 1)
    }

    /// The grey zone's insurance rebuild: once, only when nothing else is going on — and a heal that
    /// has not held yet still counts as something going on.
    @Test func permissionInsuranceRunsOnlyOnAQuietLadder() {
        var l = L()
        #expect(l.trigger(.permissionInsurance, now: 0) == .run(.rebuildAggregate, token: 1, afterSeconds: 0))
        #expect(l.rungCompleted(token: 1, succeeded: true, now: 0.3) == .awaitHeartbeat(seconds: L.heartbeatDeadlineSeconds, token: 1))
        #expect(l.heartbeatObserved(now: 0.5) == .none)
        #expect(l.trigger(.permissionInsurance, now: 10) == .none)
        #expect(l.trigger(.permissionInsurance, now: 30.5) == .run(.rebuildAggregate, token: 2, afterSeconds: 0))
        var busy = L()
        _ = busy.trigger(.stalled, now: 0)
        #expect(busy.trigger(.permissionInsurance, now: 0.1) == .none)
    }
}
