import Testing
@testable import TranscriberCore

/// #193: a mic that is delivering pure digital silence (lid closed, built-in mic stays default)
/// looks perfectly healthy to every other detector — frames ARE arriving, so no padding, no
/// `trackNeverDelivered`. `ExactZeroRunMonitor` is the one signal built specifically to catch it:
/// samples that are exactly zero, not merely quiet.
@Suite struct ExactZeroRunMonitorTests {

    private let rate = 48000.0

    /// 12 s (default threshold) of exact-zero samples, fed in 100ms batches like a real buffer
    /// cadence, must fire exactly once.
    @Test func sustainedExactZeroFiresOnce() {
        var m = ExactZeroRunMonitor(thresholdSeconds: 12)
        let batch = [Int16](repeating: 0, count: 4800)  // 0.1s @ 48kHz
        var fired = 0
        for _ in 0..<130 {  // 13s of exact zero — comfortably past the 12s threshold
            if case .silentRun = m.record(samples: batch, rate: rate) { fired += 1 }
        }
        #expect(fired == 1, "a persistent silent run must report once, not once per buffer")
    }

    /// Real audio — even very quiet, but with SOME non-zero sample — never fires. This is the
    /// property that makes the detector safe: a quiet room is not an anomaly.
    @Test func quietButNonZeroNeverFires() {
        var m = ExactZeroRunMonitor(thresholdSeconds: 12)
        var batch = [Int16](repeating: 0, count: 4800)
        batch[0] = 1  // the tiniest possible non-zero sample
        var fired = false
        for _ in 0..<200 {
            if case .silentRun = m.record(samples: batch, rate: rate) { fired = true }
        }
        #expect(!fired, "a single non-zero sample per buffer must never trip the exact-zero detector")
    }

    /// A short run of exact zeros (below threshold) must not fire — legitimate momentary gating on
    /// some hardware, or a brief real silence encoded as literal zero.
    @Test func briefExactZeroDoesNotFire() {
        var m = ExactZeroRunMonitor(thresholdSeconds: 12)
        let batch = [Int16](repeating: 0, count: 4800)
        var fired = false
        for _ in 0..<50 {  // 5s — under the 12s threshold
            if case .silentRun = m.record(samples: batch, rate: rate) { fired = true }
        }
        #expect(!fired)
    }

    /// Real audio resuming clears the run — a mic that goes exact-zero, recovers, then goes
    /// exact-zero again later (lid closed, opened, closed again) must be reported a second time.
    @Test func recoveryThenRelapseFiresTwice() {
        var m = ExactZeroRunMonitor(thresholdSeconds: 12)
        let silence = [Int16](repeating: 0, count: 4800)
        var speech = [Int16](repeating: 0, count: 4800)
        speech[100] = 500

        var fired = 0
        for _ in 0..<130 { if case .silentRun = m.record(samples: silence, rate: rate) { fired += 1 } }
        #expect(fired == 1)

        // Real audio resumes.
        for _ in 0..<20 { _ = m.record(samples: speech, rate: rate) }

        // Goes silent again.
        for _ in 0..<130 { if case .silentRun = m.record(samples: silence, rate: rate) { fired += 1 } }
        #expect(fired == 2, "a second, later silent run must be reported independently")
    }

    /// An empty batch (no samples delivered this call) must not itself count as a zero run — there
    /// is nothing to judge, and `allSatisfy` on an empty array is vacuously true, which would be a
    /// bug if not guarded against explicitly.
    @Test func emptyBatchIsIgnored() {
        var m = ExactZeroRunMonitor(thresholdSeconds: 0.001)
        let verdict = m.record(samples: [], rate: rate)
        #expect(verdict == .notYet)
    }

    /// A non-positive rate must never be judged (guards a division that would otherwise be
    /// meaningless or produce `.infinity`/`NaN`).
    @Test func nonPositiveRateNeverFires() {
        var m = ExactZeroRunMonitor(thresholdSeconds: 0.001)
        let batch = [Int16](repeating: 0, count: 4800)
        let verdict = m.record(samples: batch, rate: 0)
        #expect(verdict == .notYet)
    }
}
