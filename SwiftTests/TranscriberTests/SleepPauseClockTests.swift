import Testing
@testable import TranscriberCore

/// H2 council (A-I7 / B-M6): sleep pauses both liveness monitors, and before this only the "wake"
/// message un-paused them. A lost or reordered wake left both tracks unjudged for the rest of the
/// call. The pause now expires after 30 s of AWAKE time: uptime (mach_absolute_time) does not advance
/// while the machine sleeps, so a real sleep of any length never expires it.
@Suite struct SleepPauseClockTests {
    private let s: UInt64 = 1_000_000_000

    @Test func thePauseExpiresAfterThirtySecondsOfAwakeTimeOnce() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        #expect(c.isPaused)
        let early = c.tick(nowNanos: 129 * s)
        let due = c.tick(nowNanos: 130 * s)
        let after = c.tick(nowNanos: 131 * s)
        #expect(!early)
        #expect(due)
        #expect(!c.isPaused)
        #expect(!after, "once")
    }

    @Test func theExpiryIsThirtySeconds() {
        #expect(SleepPauseClock.expirySeconds == 30)
    }

    @Test func aWakeEndsThePauseBeforeItExpires() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        c.resume()
        let later = c.tick(nowNanos: 200 * s)
        #expect(!c.isPaused)
        #expect(!later)
    }

    /// A duplicate "sleep" (two concurrent sends) must not push the expiry back.
    @Test func aRepeatedSleepKeepsTheFirstStamp() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        c.pause(nowNanos: 120 * s)
        let due = c.tick(nowNanos: 130 * s)
        #expect(due)
    }

    @Test func notPausedNeverExpires() {
        var c = SleepPauseClock()
        let tick = c.tick(nowNanos: 1_000 * s)
        #expect(!tick)
    }
}
