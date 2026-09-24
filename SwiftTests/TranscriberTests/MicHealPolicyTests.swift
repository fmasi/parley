import Testing
@testable import TranscriberCore

/// H4 (mic side of §5): a silent mic is rebuilt first; the alarm comes only if that did not bring
/// frames back. `MicCaptureSession.attemptRecover()` has always existed; nothing called it for a
/// silent-but-not-errored session. H review round 1 (C): frames end the episode only once they have
/// held for `sustainedHealthSeconds` — a mic that bursts after every rebuild and then stalls again
/// must alarm, not be healed forever.
@Suite struct MicHealPolicyTests {
    @Test func firstSilenceHealsWithoutAlarming() {
        var p = MicHealPolicy()
        #expect(p.onVerdict(.neverDelivered(seconds: 5), now: 0) == .heal)
    }
    @Test func silenceAfterAHealAttemptAlarmsAndHealsAgain() {
        var p = MicHealPolicy()
        _ = p.onVerdict(.stalled(seconds: 3), now: 0)
        #expect(p.onVerdict(.neverDelivered(seconds: 5), now: 5) == .healAndAlarm)
        #expect(p.onVerdict(.neverDelivered(seconds: 5), now: 10) == .healAndAlarm, "still silent: still a repeat")
    }
    @Test func framesThatHoldForTheWindowEndTheEpisode() {
        var p = MicHealPolicy()
        _ = p.onVerdict(.stalled(seconds: 3), now: 0)
        #expect(p.onVerdict(.firstFrames, now: 1) == .clear)
        #expect(p.onVerdict(.stalled(seconds: 3), now: 1 + MicHealPolicy.sustainedHealthSeconds) == .heal)
    }
    @Test func aStallSoonAfterFramesIsARepeat() {
        var p = MicHealPolicy()
        _ = p.onVerdict(.stalled(seconds: 3), now: 0)
        #expect(p.onVerdict(.firstFrames, now: 1) == .clear)
        #expect(p.onVerdict(.stalled(seconds: 3), now: 10) == .healAndAlarm)
    }
    /// The review's case: every rebuild brings a burst of frames, then the mic stalls again.
    @Test func aMicThatBurstsAfterEveryRebuildStillAlarms() {
        var p = MicHealPolicy()
        var actions: [MicHealPolicy.Action] = []
        var t = 0.0
        for _ in 0..<4 {
            actions.append(p.onVerdict(.stalled(seconds: 3), now: t))
            _ = p.onVerdict(.firstFrames, now: t + 1)
            t += 5
        }
        #expect(actions == [.heal, .healAndAlarm, .healAndAlarm, .healAndAlarm])
    }
    /// Scan C11: a heal whose restart budget is exhausted never re-arms the monitor, so no second
    /// verdict arrives — the alarm must come from the failure itself.
    @Test func aHealThatExhaustsItsBudgetAlarmsWithoutASecondVerdict() {
        var p = MicHealPolicy()
        _ = p.onVerdict(.neverDelivered(seconds: 5), now: 0)
        #expect(p.healFailed(heartbeatAgeSeconds: nil, currentDevicePresent: true) == .alarm)
        #expect(p.onVerdict(.cleared(.heartbeat), now: 1) == .clear)
    }
    @Test func healthyIsNothing() {
        var p = MicHealPolicy()
        #expect(p.onVerdict(.healthy, now: 0) == .none)
    }

    // MARK: - H2 council: the reopen deadline (A-C2; round 2 items 11, 15)

    /// A reopen that blocks (gotcha #68: `stopRunning`/`startRunning` on a HAL lock), or a heal that is
    /// a no-op behind a recovery already in flight, never re-arms the monitor: its episode stays open
    /// and no second verdict comes. The deadline alarms anyway — as a STUCK reopen (round 2 item 15).
    @Test func aReopenStillInFlightAtTheDeadlineIsStuckOnce() {
        var p = MicHealPolicy()
        _ = p.onVerdict(.stalled(seconds: 3), now: 0)
        p.reopenRequested(now: 0, heartbeat: 100)
        let early = p.tick(now: MicHealPolicy.reopenDeadlineSeconds - 1, heartbeat: 100, reopenInFlight: true)
        let due = p.tick(now: MicHealPolicy.reopenDeadlineSeconds, heartbeat: 100, reopenInFlight: true)
        let after = p.tick(now: MicHealPolicy.reopenDeadlineSeconds + 1, heartbeat: 100, reopenInFlight: true)
        #expect(early == .none)
        #expect(due == .reopenStuck)
        #expect(after == .none, "once per reopen")
    }

    /// A reopen that RETURNED but delivered nothing is not stuck (round 2 item 15): it alarms, without
    /// the `recoveryStuck` label.
    @Test func aReopenThatReturnedButDeliveredNothingAlarmsWithoutBeingStuck() {
        var p = MicHealPolicy()
        p.reopenRequested(now: 0, heartbeat: 100)
        let due = p.tick(now: 8, heartbeat: 100, reopenInFlight: false)
        #expect(due == .alarm)
    }

    @Test func theDeadlineIsEightSeconds() {
        #expect(MicHealPolicy.reopenDeadlineSeconds == 8)
    }

    @Test func aReopenThatDeliversInTimeRaisesNothing() {
        var p = MicHealPolicy()
        p.reopenRequested(now: 0, heartbeat: 100)
        let delivered = p.tick(now: 2, heartbeat: 200, reopenInFlight: false)
        let later = p.tick(now: 30, heartbeat: 200, reopenInFlight: false)
        #expect(delivered == .none)
        #expect(later == .none, "no deadline left once the mic delivered")
    }

    /// Evidence clears it: the mic's first frames after the stuck reopen, whatever re-armed it (or not).
    @Test func theDeadlineAlarmClearsOnTheMicsFirstFrames() {
        var p = MicHealPolicy()
        p.reopenRequested(now: 0, heartbeat: 100)
        _ = p.tick(now: 8, heartbeat: 100, reopenInFlight: true)
        let frames = p.tick(now: 40, heartbeat: 150, reopenInFlight: false)
        let more = p.tick(now: 41, heartbeat: 160, reopenInFlight: false)
        #expect(frames == .clear)
        #expect(more == .none, "once")
    }

    /// A recovery already in flight keeps its own start: asking again does not push the deadline back.
    @Test func aSecondRequestDoesNotPushTheDeadlineBack() {
        var p = MicHealPolicy()
        p.reopenRequested(now: 0, heartbeat: 100)
        p.reopenRequested(now: 5, heartbeat: 100)
        let due = p.tick(now: 8, heartbeat: 100, reopenInFlight: true)
        #expect(due == .reopenStuck)
    }

    @Test func aStuckReopenMakesTheNextSilenceARepeat() {
        var p = MicHealPolicy()
        p.reopenRequested(now: 0, heartbeat: 100)
        _ = p.tick(now: 8, heartbeat: 100, reopenInFlight: true)
        _ = p.tick(now: 9, heartbeat: 200, reopenInFlight: false)
        #expect(p.onVerdict(.stalled(seconds: 3), now: 12) == .healAndAlarm)
    }

    /// Round 2 item 11: a deadline started before or during sleep must not survive the wake. The wake's
    /// own reopen starts a fresh deadline.
    @Test func aWakeRestartsTheReopenDeadline() {
        var p = MicHealPolicy()
        p.reopenRequested(now: 0, heartbeat: 100)
        p.reopenRequested(now: 10, heartbeat: 100, restartingDeadline: true)   // the wake's reopen
        let justAfterWake = p.tick(now: 11, heartbeat: 100, reopenInFlight: true)
        let wakeDeadline = p.tick(now: 18, heartbeat: 100, reopenInFlight: true)
        #expect(justAfterWake == .none, "not the pre-sleep deadline firing at once")
        #expect(wakeDeadline == .reopenStuck, "the wake's reopen has its own deadline")
    }

    @Test func sleepClearsAPendingReopen() {
        var p = MicHealPolicy()
        p.reopenRequested(now: 0, heartbeat: 100)
        p.slept()
        let later = p.tick(now: 20, heartbeat: 100, reopenInFlight: true)
        #expect(later == .none)
    }

    /// Round 2 item 15: a heal that gave up already raised `restartFailed` and its alarm; its deadline
    /// must not add `recoveryStuck` on top.
    @Test func aHealThatGaveUpLeavesNoDeadlineBehind() {
        var p = MicHealPolicy()
        p.reopenRequested(now: 0, heartbeat: 100)
        #expect(p.healFailed(heartbeatAgeSeconds: nil, currentDevicePresent: true) == .alarm)
        let due = p.tick(now: 8, heartbeat: 100, reopenInFlight: false)
        #expect(due == .none)
    }

    // MARK: - H2 council: a failed follow is not a dead mic (A-I5; round 2 items 12, 14)

    /// The recover loop's budget ran out while switching devices, but it failed BEFORE the swap, so
    /// the current mic keeps recording: nothing will ever clear a `micNotDelivering` raised now.
    @Test func aFailedFollowWhileTheMicStillDeliversIsAFollowFailureNotAnAlarm() {
        var p = MicHealPolicy()
        #expect(p.healFailed(heartbeatAgeSeconds: 0.1, currentDevicePresent: true) == .followFailed)
        #expect(p.onVerdict(.stalled(seconds: 3), now: 10) == .heal, "the episode was not primed: a later silence heals first")
    }

    @Test func aFailedHealOverASilentMicAlarms() {
        var p = MicHealPolicy()
        #expect(p.healFailed(heartbeatAgeSeconds: MicHealPolicy.deliveringWithinSeconds, currentDevicePresent: true) == .alarm)
        #expect(p.healFailed(heartbeatAgeSeconds: nil, currentDevicePresent: true) == .alarm, "never delivered")
    }

    /// Round 2 item 12 (minor 2): a fresh heartbeat from a device that has just vanished is not "still
    /// recording" — the liveness path owns it, and the follow failure alarms.
    @Test func aFreshHeartbeatFromAVanishedDeviceIsNotStillRecording() {
        var p = MicHealPolicy()
        #expect(p.healFailed(heartbeatAgeSeconds: 0.1, currentDevicePresent: false) == .alarm)
    }

    /// Round 2 item 14: the same rule tells the session whether to keep its current device id, so an
    /// unrelated HAL event can't tear down a mic that is still recording.
    @Test func stillRecordingNeedsAFreshHeartbeatAndThePresentDevice() {
        #expect(MicHealPolicy.stillRecording(heartbeatAgeSeconds: 0.5, currentDevicePresent: true))
        #expect(!MicHealPolicy.stillRecording(heartbeatAgeSeconds: 0.5, currentDevicePresent: false))
        #expect(!MicHealPolicy.stillRecording(heartbeatAgeSeconds: 5, currentDevicePresent: true))
        #expect(!MicHealPolicy.stillRecording(heartbeatAgeSeconds: nil, currentDevicePresent: true))
    }
}
