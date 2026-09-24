import Testing
@testable import TranscriberCore

/// H2 council (A-I7 / B-M6) + round 2 (items 11, 13, 18): sleep pauses both liveness monitors, and
/// once only the app's "wake" un-paused them — a lost wake left both tracks unjudged for the rest of
/// the call. Now a confirmed FULL wake from IOKit is an implicit wake, and the 30 s expiry clock runs
/// only after a power-on the helper could not classify: a DarkWake / Power Nap never ends the pause.
/// The wake is idempotent, and mic work that arrives while paused waits for it.
@Suite struct SleepPauseClockTests {
    private let s: UInt64 = 1_000_000_000

    @Test func aConfirmedFullWakeIsAnImplicitWakeAndALateAppWakeIsIgnored() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        let fullWake = c.poweredOn(fullWake: true, nowNanos: 200 * s)
        let appWake = c.wake()
        #expect(fullWake != nil)
        #expect(!c.isPaused)
        #expect(appWake == nil, "one wake: the app's arrives second and does nothing (item 13)")
    }

    /// Item 18: a DarkWake is awake time too, so an uptime clock started at the pause would expire in a
    /// long Power Nap and judge tracks whose devices are off.
    @Test func aDarkWakeNeverEndsThePause() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        let dark = c.poweredOn(fullWake: false, nowNanos: 110 * s)
        #expect(dark == nil)
        for t: UInt64 in 111...400 {
            let resumed = c.tick(nowNanos: t * s, fullWake: false)
            #expect(resumed == nil)
        }
        #expect(c.isPaused)
    }

    /// A DarkWake promoted to a full wake sends no second power-on: the tick sees the capability change.
    @Test func aPromotionToFullWakeSeenOnATickWakes() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        _ = c.poweredOn(fullWake: false, nowNanos: 110 * s)
        let promoted = c.tick(nowNanos: 150 * s, fullWake: true)
        #expect(promoted != nil)
        #expect(!c.isPaused)
    }

    /// A power-on the helper cannot classify starts the 30 s awake-time clock: bounded, not immediate.
    @Test func anUnclassifiedPowerOnStartsTheExpiryClock() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        let unknown = c.poweredOn(fullWake: nil, nowNanos: 500 * s)
        let early = c.tick(nowNanos: 529 * s, fullWake: nil)
        let due = c.tick(nowNanos: 530 * s, fullWake: nil)
        let after = c.tick(nowNanos: 531 * s, fullWake: nil)
        #expect(unknown == nil)
        #expect(early == nil)
        #expect(due != nil)
        #expect(after == nil, "once")
    }

    @Test func theExpiryIsThirtySeconds() {
        #expect(SleepPauseClock.expirySeconds == 30)
    }

    /// Without power notifications (registration failed) the clock starts at the pause, as in round 1.
    @Test func withoutPowerNotificationsTheClockStartsAtThePause() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s, expiryStartsNow: true)
        let early = c.tick(nowNanos: 129 * s, fullWake: nil)
        let due = c.tick(nowNanos: 130 * s, fullWake: nil)
        #expect(early == nil)
        #expect(due != nil)
    }

    @Test func aWakeEndsThePauseAndTheWakeIsIdempotent() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        let first = c.wake()
        let second = c.wake()
        let later = c.tick(nowNanos: 1_000 * s, fullWake: true)
        #expect(first != nil)
        #expect(second == nil)
        #expect(later == nil)
    }

    /// A duplicate "sleep" (the app's and IOKit's) must not push a started expiry back.
    @Test func aRepeatedSleepKeepsTheFirstStamp() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s, expiryStartsNow: true)
        c.pause(nowNanos: 120 * s, expiryStartsNow: true)
        let due = c.tick(nowNanos: 130 * s, fullWake: nil)
        #expect(due != nil)
    }

    @Test func notPausedNeverExpires() {
        var c = SleepPauseClock()
        let tick = c.tick(nowNanos: 1_000 * s, fullWake: nil)
        #expect(tick == nil)
    }

    /// Item 11: a coreaudiod restart that arrives while paused touches the mic only at the wake — its
    /// reopen's deadline would otherwise run across the sleep and fire falsely.
    @Test func aServiceRestartWhilePausedWaitsForTheWake() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        let deferred = c.deferMicWork(.serviceRestart)
        let resumed = c.wake()
        let afterWake = c.deferMicWork(.serviceRestart)
        #expect(deferred, "no mic action while paused")
        #expect(resumed == [.serviceRestart], "run at the wake")
        #expect(!afterWake, "awake: run it now")
    }

    @Test func aWakeWithNothingDeferredCarriesNoMicWork() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        let resumed = c.wake()
        #expect(resumed == [])
    }
}
