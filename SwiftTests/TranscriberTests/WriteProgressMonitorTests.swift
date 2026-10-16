import Testing
@testable import TranscriberCore

/// H2 council (A-I3): the OS calling us is not us writing. A track whose heartbeat flows while it is
/// expected, but whose written frames stop growing — a converter failure, an unsupported mic format,
/// a sticky format drop — has audio arriving that can't be recorded, and nothing else alarms it: the
/// liveness monitor judges the heartbeat, which is fine.
@Suite struct WriteProgressMonitorTests {
    private let s: UInt64 = 1_000_000_000
    private let t0: UInt64 = 100 * 1_000_000_000

    /// Ticks at t0 + `seconds`, with the heartbeat at the tick and the given frame count.
    private func tick(_ m: inout WriteProgressMonitor, at seconds: UInt64, frames: Int64,
                      heartbeatAgo: UInt64 = 0, expected: Bool = true) -> WriteProgressMonitor.Verdict {
        let now = t0 + seconds * s
        return m.check(nowNanos: now, lastHeartbeatNanos: now - heartbeatAgo * s, expected: expected, writtenFrames: frames)
    }

    @Test func heartbeatWithoutWritesForFiveSecondsIsStuckOnce() {
        var m = WriteProgressMonitor()
        var verdicts: [WriteProgressMonitor.Verdict] = []
        for t: UInt64 in 0...7 { verdicts.append(tick(&m, at: t, frames: 4_800)) }
        #expect(verdicts[0..<5].allSatisfy { $0 == .none })
        #expect(verdicts[5] == .stuck(seconds: 5))
        #expect(verdicts[6...].allSatisfy { $0 == .none }, "once per episode")
    }

    @Test func theThresholdIsFiveSeconds() {
        #expect(WriteProgressMonitor.stuckSeconds == 5)
    }

    /// An unsupported mic format from the very first buffer: nothing was ever written.
    @Test func aTrackThatNeverWroteWhileCalledIsStuck() {
        var m = WriteProgressMonitor()
        var last: WriteProgressMonitor.Verdict = .none
        for t: UInt64 in 0...5 { last = tick(&m, at: t, frames: 0) }
        #expect(last == .stuck(seconds: 5))
    }

    @Test func writeProgressClearsIt() {
        var m = WriteProgressMonitor()
        for t: UInt64 in 0...5 { _ = tick(&m, at: t, frames: 100) }
        #expect(tick(&m, at: 6, frames: 200) == .cleared)
        #expect(tick(&m, at: 7, frames: 300) == .none, "once")
    }

    @Test func steadyWritesAreNeverStuck() {
        var m = WriteProgressMonitor()
        var frames: Int64 = 0
        for t: UInt64 in 0...30 {
            frames += 48_000
            #expect(tick(&m, at: t, frames: frames) == .none)
        }
    }

    /// No heartbeat is the liveness monitor's case (stalled / never delivered), not this one.
    @Test func noHeartbeatIsNotStuck() {
        var m = WriteProgressMonitor()
        for t: UInt64 in 0...10 {
            #expect(tick(&m, at: t, frames: 100, heartbeatAgo: t + 3) == .none)
        }
        let never = m.check(nowNanos: t0 + 20 * s, lastHeartbeatNanos: 0, expected: true, writtenFrames: 100)
        #expect(never == .none)
    }

    /// The heartbeat has to FLOW for the whole window: time without it does not count.
    @Test func aHeartbeatGapRestartsTheClock() {
        var m = WriteProgressMonitor()
        for t: UInt64 in 0...3 { _ = tick(&m, at: t, frames: 100) }
        _ = tick(&m, at: 4, frames: 100, heartbeatAgo: 4)
        for t: UInt64 in 5...9 { #expect(tick(&m, at: t, frames: 100) == .none) }
        #expect(tick(&m, at: 10, frames: 100) == .stuck(seconds: 5))
    }

    /// The tap's gate: a remote that is not expected to play owes no writes, and a reported episode
    /// ends when the track stops being expected — debounced like the liveness monitor's gate, so a
    /// one-tick dropout of the call app's output neither clears the alarm nor flickers it.
    @Test func notExpectedIsNeverStuckAndEndsAReportedEpisode() {
        var m = WriteProgressMonitor()
        for t: UInt64 in 0...10 {
            #expect(tick(&m, at: t, frames: 100, expected: false) == .none)
        }
        for t: UInt64 in 11...16 { _ = tick(&m, at: t, frames: 100) }
        #expect(tick(&m, at: 17, frames: 100, expected: false) == .none, "a one-tick dropout is not the end")
        #expect(tick(&m, at: 18, frames: 100, expected: false) == .cleared)
        #expect(tick(&m, at: 19, frames: 100, expected: false) == .none)
    }

    @Test func aOneTickGateDropoutDoesNotRestartTheClock() {
        var m = WriteProgressMonitor()
        for t: UInt64 in 0...2 { _ = tick(&m, at: t, frames: 100) }
        _ = tick(&m, at: 3, frames: 100, expected: false)
        _ = tick(&m, at: 4, frames: 100)
        #expect(tick(&m, at: 5, frames: 100) == .stuck(seconds: 5))
    }
}
