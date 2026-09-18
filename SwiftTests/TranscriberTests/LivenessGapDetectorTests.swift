import Testing
@testable import TranscriberCore

/// #196: a track that delivers and then stops mid-recording is never flagged by the pad detectors
/// (they only judge on the NEXT append, which may never come). `LivenessGapDetector` is the pure
/// decision core of the 1 Hz off-audio-queue watchdog that catches this — fed timestamps, not
/// wired to any real timer or CoreAudio call.
@Suite struct LivenessGapDetectorTests {

    private func nanos(_ seconds: Double) -> UInt64 { UInt64(seconds * 1_000_000_000) }

    /// Never delivered yet (`lastArrivalNanos == 0`) is a different fault (`trackNeverDelivered`,
    /// judged only at finalize) and must not be judged here — mirrors `PadRatioMonitor`'s
    /// start-offset rule.
    @Test func neverDeliveredIsNotAGap() {
        var d = LivenessGapDetector(track: "mic", gapThresholdSeconds: 3)
        let verdict = d.check(nowNanos: nanos(100), lastArrivalNanos: 0, gateOpen: true)
        #expect(verdict == .healthy)
    }

    /// A gap under the threshold (ordinary buffer-delivery jitter) must not fire.
    @Test func shortGapIsHealthy() {
        var d = LivenessGapDetector(track: "mic", gapThresholdSeconds: 3)
        let verdict = d.check(nowNanos: nanos(101), lastArrivalNanos: nanos(100), gateOpen: true)
        #expect(verdict == .healthy)
    }

    /// A gap at/over the threshold fires exactly once, not on every subsequent tick while it persists.
    @Test func sustainedGapFiresOnce() {
        var d = LivenessGapDetector(track: "mic", gapThresholdSeconds: 3)
        var fired = 0
        for t in stride(from: 100.0, through: 130.0, by: 1.0) {
            if case .gap = d.check(nowNanos: nanos(t), lastArrivalNanos: nanos(100), gateOpen: true) {
                fired += 1
            }
        }
        #expect(fired == 1, "a persistent gap must report once, not once per tick")
    }

    /// Delivery resuming (a fresh, more recent arrival timestamp) clears the latch — a later,
    /// independent gap on the same track must be reported again.
    @Test func recoveryThenRelapseFiresTwice() {
        var d = LivenessGapDetector(track: "mic", gapThresholdSeconds: 3)
        var fired = 0
        // First gap opens and is reported.
        for t in stride(from: 100.0, through: 110.0, by: 1.0) {
            if case .gap = d.check(nowNanos: nanos(t), lastArrivalNanos: nanos(100), gateOpen: true) { fired += 1 }
        }
        #expect(fired == 1)
        // Delivery resumes (arrival advances to "now" each tick — healthy).
        for t in stride(from: 111.0, through: 115.0, by: 1.0) {
            _ = d.check(nowNanos: nanos(t), lastArrivalNanos: nanos(t), gateOpen: true)
        }
        // A second, independent gap opens later.
        for t in stride(from: 116.0, through: 126.0, by: 1.0) {
            if case .gap = d.check(nowNanos: nanos(t), lastArrivalNanos: nanos(116), gateOpen: true) { fired += 1 }
        }
        #expect(fired == 2)
    }

    /// The tap-specific gate (gotcha #66): while the gate is closed (output device idle), an
    /// arbitrarily long gap must never fire — this is exactly the false positive gotcha #66
    /// documents (a healthy recording read 97.6% zero/leading-silence in its first 30s).
    @Test func closedGateNeverFiresRegardlessOfGapLength() {
        var d = LivenessGapDetector(track: "system", gapThresholdSeconds: 3)
        var fired = false
        for t in stride(from: 0.0, through: 300.0, by: 5.0) {
            if case .gap = d.check(nowNanos: nanos(t), lastArrivalNanos: nanos(0), gateOpen: false) { fired = true }
        }
        // lastArrivalNanos is 0 here too (never delivered while idle) — also covered by the
        // never-delivered rule, but the gate must independently protect a case where the tap HAD
        // delivered before the output went idle (nonzero lastArrivalNanos, gate now closed).
        #expect(!fired)

        var d2 = LivenessGapDetector(track: "system", gapThresholdSeconds: 3)
        fired = false
        for t in stride(from: 100.0, through: 400.0, by: 5.0) {
            if case .gap = d2.check(nowNanos: nanos(t), lastArrivalNanos: nanos(100), gateOpen: false) { fired = true }
        }
        #expect(!fired, "a closed gate must suppress the gap even with a real prior arrival timestamp")
    }

    /// The gate re-opening re-arms judgement immediately — a genuine stall that happens to coincide
    /// with the output becoming active must still be caught.
    @Test func gateReopeningResumesJudgement() {
        var d = LivenessGapDetector(track: "system", gapThresholdSeconds: 3)
        // Gate closed: no judgement, whatever the gap.
        _ = d.check(nowNanos: nanos(100), lastArrivalNanos: nanos(50), gateOpen: false)
        // Gate opens; the stale arrival is now a real, sustained gap.
        let verdict = d.check(nowNanos: nanos(105), lastArrivalNanos: nanos(50), gateOpen: true)
        #expect(verdict == .gap(seconds: 55))
    }
}
