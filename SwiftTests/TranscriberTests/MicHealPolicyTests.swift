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
        #expect(p.healFailed() == .alarm)
        #expect(p.onVerdict(.cleared(.heartbeat), now: 1) == .clear)
    }
    @Test func healthyIsNothing() {
        var p = MicHealPolicy()
        #expect(p.onVerdict(.healthy, now: 0) == .none)
    }
}
