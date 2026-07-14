import Foundation
import Testing
@testable import TranscriberCore

/// The rate-drift watchdog's state machine — extracted from SystemTapSession specifically so these
/// invariants have tests, because they broke THREE times while the logic lived inline (a two-lock
/// race, then a latch-reset race, then a first-callback off-by-one). Device validation caught none
/// of them; only reasoning about the state machine did, and reasoning is what a test pins down.
@Suite struct RateDriftMonitorTests {

    private let rate = 48000.0
    private var sr: UInt64 { UInt64(48000) }
    private func nanos(_ seconds: Double) -> UInt64 { UInt64(seconds * 1_000_000_000) }

    /// Healthy delivery: frames arrive at the declared rate → never fires, keeps sliding.
    @Test func healthyDeliveryNeverFires() {
        var m = RateDriftMonitor()
        var t = 0.0
        for _ in 0..<200 {
            t += 0.1
            let v = m.record(frames: 4800, declaredRate: rate, hostNanos: nanos(t))  // 4800/0.1s = 48k
            #expect(v != .drift(effectiveRate: 0, ratio: 0) || { if case .drift = v { return false }; return true }())
            if case .drift = v { Issue.record("healthy stream should never report drift") }
        }
    }

    /// The HFP case: device delivers half the declared rate → fires once the window fills.
    @Test func halfRateDeliveryFires() {
        var m = RateDriftMonitor()
        var fired = false
        var t = 0.0
        for _ in 0..<100 {
            t += 0.1
            // Declared 48k, but only 2400 frames per 0.1s arrive = 24k actual.
            if case .drift(_, let ratio) = m.record(frames: 2400, declaredRate: rate, hostNanos: nanos(t)) {
                fired = true
                #expect(abs(ratio - 0.5) < 0.02, "ratio should reflect ~half rate")
                break
            }
        }
        #expect(fired, "a sustained half-rate stream must be reported")
    }

    /// A 44.1/48 mismatch (ratio 0.919) must be caught — the original 0.9–1.1 band could not see it.
    @Test func fortyFourOneMismatchIsCaught() {
        var m = RateDriftMonitor()
        var fired = false
        var t = 0.0
        for _ in 0..<100 {
            t += 0.1
            // Declared 48k, actually delivering 44100: 4410 frames per 0.1s.
            if case .drift = m.record(frames: 4410, declaredRate: rate, hostNanos: nanos(t)) {
                fired = true
                break
            }
        }
        #expect(fired, "a 44.1/48 mismatch (ratio 0.919) must be inside the band")
    }

    /// It does not judge before the window fills — startup jitter must not false-fire.
    @Test func doesNotFireBeforeWindow() {
        var m = RateDriftMonitor(windowSeconds: 5)
        // Feed 2s of catastrophically wrong rate; still too early to judge.
        var t = 0.0
        for _ in 0..<20 {
            t += 0.1
            let v = m.record(frames: 100, declaredRate: rate, hostNanos: nanos(t))
            if case .drift = v { Issue.record("must not judge before the window fills") }
        }
    }

    /// Reports only ONCE — it's a persistent condition, not a per-callback event.
    @Test func reportsOnce() {
        var m = RateDriftMonitor()
        var fireCount = 0
        var t = 0.0
        for _ in 0..<200 {
            t += 0.1
            if case .drift = m.record(frames: 2400, declaredRate: rate, hostNanos: nanos(t)) {
                fireCount += 1
            }
        }
        #expect(fireCount == 1, "drift must latch and report exactly once, not every callback")
    }

    /// THE INVARIANT THAT BROKE THREE TIMES, part 1: a rebuild's dead window must not false-fire.
    /// Fill most of a window healthily, `reset()` (as a device rebuild does), then a gap in host
    /// time (frames stopped during the rebuild) must NOT be read as a deficit against old frames.
    @Test func resetPreventsRebuildFalseAlarm() {
        var m = RateDriftMonitor()
        var t = 0.0
        // Healthy for 4s.
        for _ in 0..<40 { t += 0.1; _ = m.record(frames: 4800, declaredRate: rate, hostNanos: nanos(t)) }

        m.reset()   // device rebuild

        // 0.8s dead window (no frames delivered), then healthy delivery resumes.
        t += 0.8
        var falseAlarm = false
        for _ in 0..<60 {
            t += 0.1
            if case .drift = m.record(frames: 4800, declaredRate: rate, hostNanos: nanos(t)) {
                falseAlarm = true
            }
        }
        #expect(!falseAlarm, "a reset generation must not be judged on the dead rebuild window")
    }

    /// Part 2: after a rebuild, a genuine drift in the NEW generation must still fire — reset must
    /// not permanently disarm the watchdog (the latch-reset race).
    @Test func rearmsAfterReset() {
        var m = RateDriftMonitor()
        var t = 0.0
        // First generation drifts and fires.
        for _ in 0..<100 { t += 0.1; _ = m.record(frames: 2400, declaredRate: rate, hostNanos: nanos(t)) }

        m.reset()   // new aggregate generation

        var firedAgain = false
        for _ in 0..<100 {
            t += 0.1
            if case .drift = m.record(frames: 2400, declaredRate: rate, hostNanos: nanos(t)) {
                firedAgain = true
                break
            }
        }
        #expect(firedAgain, "reset must re-arm the watchdog for the new generation, not disarm it")
    }

    /// First callback's frames are counted (the off-by-one that under-counted the rate by one buffer).
    @Test func firstCallbackFramesAreCounted() {
        var m = RateDriftMonitor(windowSeconds: 1)
        // Two callbacks: t=0 anchors, t=1s judges. If the first callback's frames were dropped, the
        // effective rate would be halved and this healthy stream would false-fire.
        _ = m.record(frames: 48000, declaredRate: rate, hostNanos: nanos(0))
        let v = m.record(frames: 48000, declaredRate: rate, hostNanos: nanos(1))
        if case .drift = v { Issue.record("first callback's frames must count — this stream is healthy") }
    }

    @Test func zeroDeclaredRateIsIgnored() {
        var m = RateDriftMonitor()
        #expect(m.record(frames: 4800, declaredRate: 0, hostNanos: nanos(1)) == .notYet)
    }
}
