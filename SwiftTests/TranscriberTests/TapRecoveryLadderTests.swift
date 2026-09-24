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
        #expect(l.heartbeatDeadlineMissed(now: 0.4) == .none)
        #expect(l.inFlightToken == 2 && l.totalRebuilds == 2)
    }

    @Test func aSuccessfulRungWaitsForAHeartbeat() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.rungCompleted(token: 1, succeeded: true, now: 0.4) == .awaitHeartbeat(seconds: L.heartbeatDeadlineSeconds))
        #expect(l.trigger(.stalled, now: 1) == .none, "already waiting; a verdict must not start a second rebuild")
    }

    @Test func aHeartbeatClosesTheEpisode() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.4)
        #expect(l.heartbeatObserved() == .none)
        #expect(l.inFlight == nil && !l.awaitingHeartbeat && !l.exhausted)
        #expect(l.trigger(.stalled, now: 100) == .run(.rebuildAggregate, token: 2, afterSeconds: 0), "a later, separate stall starts a fresh episode")
    }

    @Test func missedHeartbeatBacksOffThenEscalatesToTheTapRung() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.3)
        #expect(l.heartbeatDeadlineMissed(now: 3.3) == .run(.rebuildAggregate, token: 2, afterSeconds: 0.25))
        _ = l.rungCompleted(token: 2, succeeded: true, now: 3.9)
        #expect(l.heartbeatDeadlineMissed(now: 6.9) == .run(.rebuildTap, token: 3, afterSeconds: 0.5))
        _ = l.rungCompleted(token: 3, succeeded: true, now: 7.6)
        #expect(l.heartbeatDeadlineMissed(now: 10.6) == .run(.rebuildTap, token: 4, afterSeconds: 1))
    }

    @Test func aThrownRungMovesOnAfterBackoff() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.rungCompleted(token: 1, succeeded: false, now: 0.2) == .run(.rebuildAggregate, token: 2, afterSeconds: 0.25))
    }

    private func exhaust(_ l: inout L) {
        _ = l.trigger(.stalled, now: 0)
        for _ in 0..<4 {
            _ = l.rungCompleted(token: l.inFlightToken!, succeeded: true, now: 1)
            _ = l.heartbeatDeadlineMissed(now: 4)
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
            _ = l.rungCompleted(token: l.inFlightToken!, succeeded: true, now: 1)
            last = l.heartbeatDeadlineMissed(now: 4)
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
        #expect(l.rungCompleted(token: 5, succeeded: true, now: 63.8) == .awaitHeartbeat(seconds: L.heartbeatDeadlineSeconds))
        #expect(l.slowRetryDue(now: 64) == .none)
        #expect(l.heartbeatDeadlineMissed(now: 66.8) == .giveUp(retryAfterSeconds: L.slowRetrySeconds))
        #expect(l.slowRetryDue(now: 126.8) == .run(.rebuildTap, token: 6, afterSeconds: 0))
    }

    @Test func aFastWindowTimeoutGivesUpEvenWithBudgetLeft() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.5)
        #expect(l.heartbeatDeadlineMissed(now: 20) == .giveUp(retryAfterSeconds: L.slowRetrySeconds))
    }

    /// coreaudiod restart: every id is dead, nothing below a new tap can help.
    @Test func serviceRestartedJumpsStraightToANewTap() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)
        #expect(l.trigger(.serviceRestarted, now: 0.1) == .run(.rebuildTap, token: 2, afterSeconds: 0))
    }

    /// The old rung's result arriving after a service restart must not complete the new rung.
    @Test func aStaleRungResultAfterAServiceRestartIsIgnored() {
        var l = L()
        _ = l.trigger(.stalled, now: 0)                                   // token 1
        _ = l.trigger(.serviceRestarted, now: 0.1)                        // token 2
        #expect(l.rungCompleted(token: 1, succeeded: true, now: 0.3) == .none)
        #expect(l.inFlight == .rebuildTap && l.inFlightToken == 2)
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
        #expect(l.rungCompleted(token: 1, succeeded: true, now: 0.4) == .awaitHeartbeat(seconds: L.heartbeatDeadlineSeconds))
        // The external rebuild used one of the two aggregate attempts: the next miss escalates to the tap rung.
        #expect(l.heartbeatDeadlineMissed(now: 3.4) == .run(.rebuildTap, token: 2, afterSeconds: 0.25))
    }

    @Test func anExternalRebuildOutsideAnEpisodeCostsNoBudget() {
        var l = L()
        _ = l.noteExternalRebuild(now: 0)
        #expect(l.totalRebuilds == 1)
        _ = l.trigger(.stalled, now: 10)
        _ = l.rungCompleted(token: 1, succeeded: true, now: 10.3)
        #expect(l.heartbeatDeadlineMissed(now: 13.3) == .run(.rebuildAggregate, token: 2, afterSeconds: 0.25), "both aggregate attempts still available")
    }

    /// Spec §5 (scan C10): the slow retry runs only while the gate stays open; when the gate closes
    /// the episode ends, and a still-dead tap when it reopens gets a fresh fast episode, not a 60 s wait.
    @Test func gateClosedResetsAnExhaustedLadder() {
        var l = L()
        exhaust(&l)
        #expect(l.exhausted)
        #expect(l.gateClosed() == .none)
        #expect(!l.exhausted && l.inFlight == nil && !l.awaitingHeartbeat)
        #expect(l.trigger(.neverDelivered, now: 100) == .run(.rebuildAggregate, token: 5, afterSeconds: 0))
    }

    /// A grant reaches only a tap built after it: never budgeted, never delayed, even when exhausted.
    @Test func permissionGrantRunsEvenWhenExhausted() {
        var l = L()
        exhaust(&l)
        #expect(l.trigger(.permissionGrant, now: 5) == .run(.rebuildAggregate, token: 5, afterSeconds: 0))
    }

    /// The grey zone's insurance rebuild: once, only when nothing else is going on.
    @Test func permissionInsuranceRunsOnlyOnAQuietLadder() {
        var l = L()
        #expect(l.trigger(.permissionInsurance, now: 0) == .run(.rebuildAggregate, token: 1, afterSeconds: 0))
        _ = l.rungCompleted(token: 1, succeeded: true, now: 0.3)
        _ = l.heartbeatObserved()
        var busy = L()
        _ = busy.trigger(.stalled, now: 0)
        #expect(busy.trigger(.permissionInsurance, now: 0.1) == .none)
    }
}
