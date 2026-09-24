import Testing
@testable import TranscriberCore

/// L-N1 (validated lifecycle §2.1): launchd idle-exits the helper ~10 min after the app goes
/// quiet. The client read that as a crash, latched "handled", and never ran recovery again for
/// the life of the process — the 2026-09-24 16:00 recording ran with crash detection disarmed.
@Suite struct XPCInterruptionPolicyTests {

    @Test func idleInterruptionIsIgnoredWithoutPingOrLatch() {
        var p = XPCInterruptionPolicy()
        #expect(p.onInterruption(classification: .transientBlip) == .ignoreIdle)
        #expect(p.onInvalidation() == .ignoreIdle)
        #expect(p.expectingCapture == false)
    }

    /// The exact incident shape: an idle-exit, then a recording starts, then a real crash.
    @Test func crashAfterAnIdleInterruptionStillFires() {
        var p = XPCInterruptionPolicy()
        _ = p.onInterruption(classification: .transientBlip)
        _ = p.onInvalidation()
        p.captureStarted()
        #expect(p.onInterruption(classification: .likelyCrash) == .crash)
    }

    @Test func blipVerifiesThenEscalatesOnceWhenTheHelperIsNotCapturing() {
        var p = XPCInterruptionPolicy()
        p.captureStarted()
        let gen = p.captureGeneration
        #expect(p.onInterruption(classification: .transientBlip) == .verifyCapture)
        #expect(p.onVerified(stillCapturing: false, generation: gen) == .crash)
        // The trailing invalidation of the same dead connection must not fire a second recovery.
        #expect(p.onInvalidation() == .ignoreIdle)
    }

    @Test func blipWithTheHelperStillCapturingIsBrief() {
        var p = XPCInterruptionPolicy()
        p.captureStarted()
        let gen = p.captureGeneration
        _ = p.onInterruption(classification: .transientBlip)
        #expect(p.onVerified(stillCapturing: true, generation: gen) == .briefInterruption)
        // Still armed: a later real crash fires.
        #expect(p.onInvalidation() == .crash)
    }

    /// A restart bumped the generation while a verification ping from the old one was in flight.
    @Test func verificationFromAPreviousGenerationIsIgnored() {
        var p = XPCInterruptionPolicy()
        p.captureStarted()
        let old = p.captureGeneration
        _ = p.onInterruption(classification: .transientBlip)
        p.captureStarted()
        #expect(p.onVerified(stillCapturing: false, generation: old) == .ignoreIdle)
    }

    @Test func stopDisarms() {
        var p = XPCInterruptionPolicy()
        p.captureStarted()
        p.captureStopped()
        #expect(p.onInvalidation() == .ignoreIdle)
        #expect(p.onInterruption(classification: .likelyCrash) == .ignoreIdle)
    }

    @Test func aRestartReArmsAfterACrash() {
        var p = XPCInterruptionPolicy()
        p.captureStarted()
        #expect(p.onInvalidation() == .crash)
        #expect(p.onInvalidation() == .ignoreIdle)   // one recovery per generation
        p.captureStarted()                           // the coordinator's restart
        #expect(p.onInvalidation() == .crash)
    }
}
