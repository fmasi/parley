import Testing
@testable import TranscriberCore

/// The mechanism-independent backstop.
///
/// On 2026-08-04 the tap delivered ~24738 fps against a declared 48000, so `timelineSilencePad`
/// inserted a small catch-up pad before EVERY buffer to hold the wall clock. Measured on the real
/// file: 61.1% of the stream was zero-runs across 56,737 discrete runs averaging 15.6 ms — while the
/// healthy mic track was 0.1%. The pads were computed, logged 57,000 times at info level, and never
/// counted. Nothing anywhere compared them to the total.
///
/// Padding is legitimate (start skew, restart gaps) but it only ever happens when delivered frames
/// fall behind wall clock — it measures DELIVERY DEFICIT, not quiet audio. A quiet remote still
/// delivers buffers of zeros and pads nothing. That is what makes the ratio a near-false-positive-free
/// signal, and why it catches any future clock lie regardless of mechanism.
@Suite struct PadRatioMonitorTests {

    private static func rate() -> Double { 48000 }

    // MARK: - The incident

    /// ~50% deficit sustained. This is the shape that must never pass silently again.
    @Test func halfRateDeliveryIsFlagged() {
        var monitor = PadRatioMonitor()
        // 60s of audio where every second needs ~0.5s of catch-up padding. The verdict latches once,
        // so keep the FIRST non-quiet answer rather than the last call's.
        var fired: PadRatioMonitor.Verdict?
        for _ in 0..<60 {
            let v = monitor.record(padFrames: 24_000, dataFrames: 24_000, rate: Self.rate())
            if case .excessive = v, fired == nil { fired = v }
        }
        guard case .excessive(let ratio, _, _) = fired else {
            Issue.record("expected .excessive, got \(String(describing: fired))")
            return
        }
        #expect(ratio > 0.45 && ratio < 0.55)
    }

    /// Reports ONCE — this is a persistent condition, and 57,000 notifications is how the original
    /// signal got lost in the first place.
    @Test func reportsOnlyOnce() {
        var monitor = PadRatioMonitor()
        for _ in 0..<60 { _ = monitor.record(padFrames: 24_000, dataFrames: 24_000, rate: Self.rate()) }
        let after = monitor.record(padFrames: 24_000, dataFrames: 24_000, rate: Self.rate())
        #expect(after == .notYet)
    }

    // MARK: - Legitimate padding must stay quiet

    /// One second of start skew across a 24-minute meeting is ~0.07%. Nowhere near the threshold.
    @Test func startSkewIsNotFlagged() {
        var monitor = PadRatioMonitor()
        var verdict = monitor.record(padFrames: 48_000, dataFrames: 0, rate: Self.rate())   // 1s skew
        for _ in 0..<(24 * 60) {
            verdict = monitor.record(padFrames: 0, dataFrames: 48_000, rate: Self.rate())
        }
        #expect(verdict == .healthy)
    }

    /// A couple of multi-second restart gaps in a long meeting are expected and must not cry wolf.
    @Test func restartGapsAreNotFlagged() {
        var monitor = PadRatioMonitor()
        var verdict = PadRatioMonitor.Verdict.notYet
        for minute in 0..<24 {
            // 3s of gap at two points in the meeting.
            let pad: Int64 = (minute == 5 || minute == 17) ? 48_000 * 3 : 0
            verdict = monitor.record(padFrames: pad, dataFrames: 48_000 * 60, rate: Self.rate())
        }
        #expect(verdict == .healthy)
    }

    // MARK: - Warm-up

    /// Leading silence dominates the ratio before any real audio arrives, so a verdict must wait for
    /// enough material to judge — otherwise every recording trips on its own first second.
    @Test func staysSilentUntilEnoughAudio() {
        var monitor = PadRatioMonitor()
        let verdict = monitor.record(padFrames: 48_000, dataFrames: 0, rate: Self.rate())
        #expect(verdict == .notYet)
    }

    @Test func thresholdBoundaryIsRespected() {
        var monitor = PadRatioMonitor(threshold: 0.10, minimumSeconds: 30)
        var verdict = PadRatioMonitor.Verdict.notYet
        // Exactly 5% padding sustained over well past the warm-up — under the bar, stays quiet.
        for _ in 0..<120 {
            verdict = monitor.record(padFrames: 2_400, dataFrames: 45_600, rate: Self.rate())
        }
        #expect(verdict == .healthy)
    }

    // MARK: - Hygiene

    @Test func resetClearsStateAndRearms() {
        var monitor = PadRatioMonitor()
        for _ in 0..<60 { _ = monitor.record(padFrames: 24_000, dataFrames: 24_000, rate: Self.rate()) }
        monitor.reset()
        var fired: PadRatioMonitor.Verdict?
        for _ in 0..<60 {
            let v = monitor.record(padFrames: 24_000, dataFrames: 24_000, rate: Self.rate())
            if case .excessive = v, fired == nil { fired = v }
        }
        // Re-armed: the same condition is reported again for the new generation.
        guard case .excessive = fired else {
            Issue.record("expected .excessive after reset, got \(String(describing: fired))")
            return
        }
    }

    @Test func zeroRateIsSafe() {
        var monitor = PadRatioMonitor()
        #expect(monitor.record(padFrames: 100, dataFrames: 100, rate: 0) == .notYet)
    }
}
