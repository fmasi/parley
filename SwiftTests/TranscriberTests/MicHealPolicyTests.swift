import Testing
@testable import TranscriberCore

/// H4 (mic side of §5): a silent mic is rebuilt first; the alarm comes only if that did not bring
/// frames back. `MicCaptureSession.attemptRecover()` has always existed; nothing called it for a
/// silent-but-not-errored session.
@Suite struct MicHealPolicyTests {
    @Test func firstSilenceHealsWithoutAlarming() {
        var p = MicHealPolicy()
        #expect(p.onVerdict(.neverDelivered(seconds: 5)) == .heal)
    }
    @Test func silenceAfterAHealAttemptAlarmsAndHealsAgain() {
        var p = MicHealPolicy()
        _ = p.onVerdict(.stalled(seconds: 3))
        #expect(p.onVerdict(.neverDelivered(seconds: 5)) == .healAndAlarm)
        #expect(p.onVerdict(.neverDelivered(seconds: 5)) == .heal)
    }
    @Test func framesClearTheEpisode() {
        var p = MicHealPolicy()
        _ = p.onVerdict(.stalled(seconds: 3))
        #expect(p.onVerdict(.firstFrames) == .clear)
        #expect(p.onVerdict(.stalled(seconds: 3)) == .heal)
    }
    /// Scan C11: a heal whose restart budget is exhausted never re-arms the monitor, so no second
    /// verdict arrives — the alarm must come from the failure itself.
    @Test func aHealThatExhaustsItsBudgetAlarmsWithoutASecondVerdict() {
        var p = MicHealPolicy()
        _ = p.onVerdict(.neverDelivered(seconds: 5))
        #expect(p.healFailed() == .alarm)
        #expect(p.onVerdict(.cleared(.heartbeat)) == .clear)
    }
    @Test func healthyIsNothing() {
        var p = MicHealPolicy()
        #expect(p.onVerdict(.healthy) == .none)
    }
}
