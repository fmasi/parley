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

    // MARK: - The early window (council finding)

    /// A ratio alone fires far too easily near the start: a single gap of G seconds evaluated at
    /// t=30s reads G/30, so a 4-second gap is 13% and trips. Real 4-second gaps at the start of a
    /// healthy recording are ORDINARY — a Bluetooth mic taking seconds to negotiate HFP, or one #86
    /// restart whose first liveness probe misses. Crying wolf on the start of a normal meeting would
    /// make the whole signal worthless within a week. An absolute floor is what separates them.
    @Test func bluetoothMicBringUpAtStartDoesNotFire() {
        var monitor = PadRatioMonitor()
        var fired: PadRatioMonitor.Verdict?
        // 3.5s of leading pad while the headset negotiates, then a clean minute of audio.
        var v = monitor.record(padFrames: 48_000 * 7 / 2, dataFrames: 0, rate: Self.rate())
        if case .excessive = v { fired = v }
        for _ in 0..<60 {
            v = monitor.record(padFrames: 0, dataFrames: 48_000, rate: Self.rate())
            if case .excessive = v, fired == nil { fired = v }
        }
        #expect(fired == nil, "a 3.5s start gap must not be called corruption")
    }

    /// The worst realistic benign case: an SCK restart at the start costing ~8s (rebuild + a missed
    /// 4s liveness probe + backoff), inside the first 30 seconds.
    @Test func earlyRestartGapDoesNotFire() {
        var monitor = PadRatioMonitor()
        var fired: PadRatioMonitor.Verdict?
        var v = monitor.record(padFrames: 48_000 * 8, dataFrames: 0, rate: Self.rate())
        if case .excessive = v { fired = v }
        for _ in 0..<120 {
            v = monitor.record(padFrames: 0, dataFrames: 48_000, rate: Self.rate())
            if case .excessive = v, fired == nil { fired = v }
        }
        #expect(fired == nil, "an 8s early restart gap must not be called corruption")
    }

    /// The floor must not blunt real detection: a ~50% deficit accrues the absolute floor within
    /// seconds, so the incident is still caught almost as fast as before.
    @Test func realDeficitStillFiresPromptly() {
        var monitor = PadRatioMonitor()
        var firedAtSecond: Int?
        for second in 1...120 {
            let v = monitor.record(padFrames: 24_000, dataFrames: 24_000, rate: Self.rate())
            if case .excessive = v, firedAtSecond == nil { firedAtSecond = second }
        }
        guard let firedAtSecond else {
            Issue.record("half-rate delivery must still fire")
            return
        }
        #expect(firedAtSecond <= 45, "detection should stay prompt, fired at \(firedAtSecond)s")
    }

    // MARK: - THE 2026-08-11 FALSE POSITIVE (device-observed)

    /// The first real-world firing of this detector was WRONG, and the recording was healthy.
    ///
    /// A call recorded on speaker: capture started at 11:59:44, the call audio began ~60s later.
    /// Measured zero-sample ratio on the system track — 97.6% in 0-30s, 2.8% from 60-300s, 4.2%
    /// overall. Nothing was wrong with it. But the monitor judged at exactly t=30s and saw 27s of
    /// padding in 30s (ratio 0.911), clearing both the ratio threshold and the 15s absolute floor.
    ///
    /// The cause is a property of the Core Audio tap that SCK does not share: the tap delivers no
    /// buffers at all while the output device is idle. Before the call connects there is genuinely
    /// nothing to capture, so the padder fills wall clock and every one of those frames counts as
    /// "fabricated". Starting a recording before joining the call is the single most common way to
    /// use this app, so this fires on the ordinary case.
    ///
    /// The distinction that matters: padding BEFORE a track has ever delivered data is a start
    /// offset, not a deficit. Only once frames are flowing does missing frames mean something.
    @Test func leadingSilenceBeforeTheCallStartsIsNotCorruption() {
        var monitor = PadRatioMonitor()
        var fired: PadRatioMonitor.Verdict?
        // 60s of pure padding — the tap delivers nothing while the output device is idle.
        for _ in 0..<60 {
            let v = monitor.record(padFrames: 48_000, dataFrames: 0, rate: Self.rate())
            if case .excessive = v, fired == nil { fired = v }
        }
        // Then the call connects and audio flows normally for 5 minutes.
        for _ in 0..<300 {
            let v = monitor.record(padFrames: 0, dataFrames: 48_000, rate: Self.rate())
            if case .excessive = v, fired == nil { fired = v }
        }
        #expect(fired == nil, "a recording started before the call must not be called corrupted")
    }

    /// The corollary that must still hold: once a track HAS delivered data, a sustained deficit is
    /// real and must fire. This is the 2026-08-04 shape — the tap was delivering (a call was
    /// connected) at roughly half the declared rate.
    @Test func deficitAfterDataStartsStillFires() {
        var monitor = PadRatioMonitor()
        var fired: PadRatioMonitor.Verdict?
        // Leading silence first — must be ignored, not merely diluted.
        for _ in 0..<60 {
            _ = monitor.record(padFrames: 48_000, dataFrames: 0, rate: Self.rate())
        }
        // Now frames flow, but only half of what the declared rate implies.
        for _ in 0..<60 {
            let v = monitor.record(padFrames: 24_000, dataFrames: 24_000, rate: Self.rate())
            if case .excessive = v, fired == nil { fired = v }
        }
        guard case .excessive(let ratio, _, _) = fired else {
            Issue.record("a real deficit after data starts must still fire, got \(String(describing: fired))")
            return
        }
        // The leading silence must not inflate the ratio either — this is ~0.5, not ~0.8.
        #expect(ratio > 0.45 && ratio < 0.55, "leading silence must be excluded from the ratio, got \(ratio)")
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
