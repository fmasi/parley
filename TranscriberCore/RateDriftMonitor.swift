import Foundation

/// Watches whether an audio device is delivering frames at the rate it *claims* to.
///
/// Bluetooth A2DP → HFP is not a device change, so no output-switch listener fires; the IOProc keeps
/// converting against a stale format, half the frames arrive, the writer pads silence to hold the
/// wall clock, and the remote audio comes out too fast with gaps — correct duration, corrupt content.
/// This compares frames actually delivered against elapsed host time and reports a sustained shortfall.
///
/// This is the pure state machine, extracted from `SystemTapSession` so it can be unit-tested. The
/// invariant it exists to protect broke THREE times when it lived inline: the accumulate/judge/latch
/// steps must advance ATOMICALLY (the caller holds one lock across `record`), and a device rebuild
/// must `reset()` so the next aggregate generation is never judged on the previous generation's frames
/// across a dead rebuild window. Both failure modes are asserted in the tests.
public struct RateDriftMonitor {

    /// What the caller should do after feeding a callback in.
    public enum Verdict: Equatable {
        /// Not enough evidence yet (still filling the window, or already reported).
        case notYet
        /// Delivered rate is within tolerance of declared; the window has been slid forward.
        case healthy
        /// Sustained mismatch. Reports ONCE — this is a persistent condition, not a glitch, and the
        /// recording is already compromised by the time we can tell.
        case drift(effectiveRate: Double, ratio: Double)
    }

    /// Minimum window before judging, so startup jitter and drift compensation settle out.
    public let windowSeconds: Double
    /// Ratio band. Must be tight enough to see a 44.1/48 kHz mismatch (ratio 0.919) — the original
    /// 0.9–1.1 window structurally could not.
    public let lowerRatio: Double
    public let upperRatio: Double

    private var firstHostNanos: UInt64 = 0
    private var frames: Int = 0
    private var reported = false

    public init(windowSeconds: Double = 5, lowerRatio: Double = 0.95, upperRatio: Double = 1.05) {
        self.windowSeconds = windowSeconds
        self.lowerRatio = lowerRatio
        self.upperRatio = upperRatio
    }

    /// Feed one IOProc callback. `mutating` and single-pass by design: the caller advances the whole
    /// state machine under one lock so a teardown cannot land between accumulate and latch.
    public mutating func record(frames newFrames: Int, declaredRate: Double, hostNanos: UInt64) -> Verdict {
        guard declaredRate > 0, !reported else { return .notYet }

        // Count the first callback's frames too: measuring elapsed from callback 0 while counting
        // frames from callback 1 would under-count the rate by one buffer.
        frames += newFrames
        if firstHostNanos == 0 {
            firstHostNanos = hostNanos
            return .notYet
        }

        let elapsed = Double(hostNanos &- firstHostNanos) / 1_000_000_000
        guard elapsed >= windowSeconds else { return .notYet }

        let effectiveRate = Double(frames) / elapsed
        let ratio = effectiveRate / declaredRate
        if ratio < lowerRatio || ratio > upperRatio {
            reported = true
            return .drift(effectiveRate: effectiveRate, ratio: ratio)
        }

        // Healthy: slide the window forward so a rate change LATER in the meeting is still caught,
        // rather than latching an early verdict.
        firstHostNanos = hostNanos
        frames = 0
        return .healthy
    }

    /// Reset for a new aggregate generation (a device rebuild). Without this, the next generation is
    /// judged on the previous one's accumulated frames across the dead rebuild window — a spurious
    /// alarm — and a stale `reported` latch would permanently disarm the new generation.
    public mutating func reset() {
        firstHostNanos = 0
        frames = 0
        reported = false
    }
}
