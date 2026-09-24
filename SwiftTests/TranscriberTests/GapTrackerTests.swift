import Testing
@testable import TranscriberCore

/// H review round 1 (B): the record must state how long a track was silent, not the 3 s it took to
/// notice. Incident B's 29 minutes read "~3 s" in `remote_longest_gap_seconds` before this.
@Suite struct GapTrackerTests {
    private func ns(_ seconds: Double) -> UInt64 { UInt64(seconds * 1e9) }

    @Test func aStallRecordsItsRealDurationNotTheDetectionThreshold() {
        var g = GapTracker()
        g.note(.stalled(seconds: 3), track: .system, nowNanos: ns(103))                // silent since 100
        g.note(.cleared(.heartbeat), track: .system, nowNanos: ns(100 + 29 * 60))
        #expect(g.longestGapSeconds(.system, nowNanos: ns(5_000)) == 29 * 60)
        #expect(g.gapCount(.system) == 1)
    }

    @Test func aGapStillOpenCountsUpToNow() {
        var g = GapTracker()
        g.note(.neverDelivered(seconds: 5), track: .mic, nowNanos: ns(10))              // since 5
        #expect(g.longestGapSeconds(.mic, nowNanos: ns(65)) == 60)
        #expect(g.gapCount(.mic) == 1)
    }

    @Test func theLongestOfSeveralGapsWinsAndEachCountsOnce() {
        var g = GapTracker()
        g.note(.stalled(seconds: 3), track: .mic, nowNanos: ns(13))
        g.note(.firstFrames, track: .mic, nowNanos: ns(20))                              // 10 s
        g.note(.stalled(seconds: 3), track: .mic, nowNanos: ns(33))
        g.note(.cleared(.gateClosed), track: .mic, nowNanos: ns(35))                     // 5 s
        #expect(g.gapCount(.mic) == 2)
        #expect(g.longestGapSeconds(.mic, nowNanos: ns(100)) == 10)
    }

    /// An accelerator's early stall and the tick's own verdict describe one gap, from the first.
    @Test func aSecondVerdictInsideAnOpenGapIsTheSameGap() {
        var g = GapTracker()
        g.note(.stalled(seconds: 1), track: .system, nowNanos: ns(11))                   // since 10
        g.note(.stalled(seconds: 3), track: .system, nowNanos: ns(14))
        g.note(.cleared(.heartbeat), track: .system, nowNanos: ns(30))
        #expect(g.gapCount(.system) == 1)
        #expect(g.longestGapSeconds(.system, nowNanos: ns(30)) == 20)
    }

    @Test func tracksAreIndependentAndAClearWithoutAGapIsNothing() {
        var g = GapTracker()
        g.note(.cleared(.heartbeat), track: .mic, nowNanos: ns(5))
        g.note(.stalled(seconds: 3), track: .system, nowNanos: ns(13))
        #expect(g.gapCount(.mic) == 0)
        #expect(g.longestGapSeconds(.mic, nowNanos: ns(20)) == 0)
        #expect(g.longestGapSeconds(.system, nowNanos: ns(20)) == 10)
    }
}
