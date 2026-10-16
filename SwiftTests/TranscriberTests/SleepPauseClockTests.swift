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
    /// long Power Nap and judge tracks whose devices are off. Round 3 (B): not "never" either — a power-on
    /// that reads DarkWake starts the LONG clock.
    @Test func aDarkWakeDoesNotEndThePauseBeforeTheLongExpiry() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        let dark = c.poweredOn(fullWake: false, nowNanos: 110 * s)
        #expect(dark == nil)
        for t: UInt64 in 111..<(110 + 300) {
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

    /// Round 4 (N1): each sleep is its own cycle — a second sleep restarts the clock, so every wake is
    /// bounded on its own and no clock carries over from an earlier Power Nap.
    @Test func aSecondSleepStartsANewCycle() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s, expiryStartsNow: true)
        c.pause(nowNanos: 120 * s, expiryStartsNow: true)
        let oldBound = c.tick(nowNanos: 130 * s, fullWake: nil)
        let newBound = c.tick(nowNanos: 150 * s, fullWake: nil)
        #expect(oldBound == nil, "the first sleep's clock is gone")
        #expect(newBound != nil, "the second sleep's own bound")
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

    // MARK: - Round 3 (item 18, A/B): the state machine, table-tested

    @Test func theLongExpiryIsFiveMinutes() {
        #expect(SleepPauseClock.darkPowerOnExpirySeconds == 300)
    }

    /// A: the ~5 s "darkwakelinger" before a clamshell sleep reads full-wake with no power-on since the
    /// pause: that is the machine still going TO sleep, not waking.
    @Test func aFullWakeReadingWithNoPowerOnOrDarkWakeSinceThePauseIsIgnored() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        for t: UInt64 in 101...105 {
            let resumed = c.tick(nowNanos: t * s, fullWake: true)
            #expect(resumed == nil)
        }
        #expect(c.isPaused)
    }

    /// B: a power-on that reads DarkWake, then ticks that keep reading DarkWake, still end at 5 min.
    @Test func aDarkPowerOnExpiresAtFiveMinutes() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        _ = c.poweredOn(fullWake: false, nowNanos: 200 * s)
        let early = c.tick(nowNanos: 499 * s, fullWake: false)
        let due = c.tick(nowNanos: 500 * s, fullWake: false)
        #expect(early == nil)
        #expect(due != nil)
    }

    @Test func anUnknownPowerOnExpiresAtThirtySeconds() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        _ = c.poweredOn(fullWake: nil, nowNanos: 200 * s)
        let early = c.tick(nowNanos: 229 * s, fullWake: nil)
        let due = c.tick(nowNanos: 230 * s, fullWake: nil)
        #expect(early == nil)
        #expect(due != nil)
    }

    /// A dark-to-full promotion seen by the ticks alone (no power-on message at all).
    @Test func aDarkTickThenAFullTickWakes() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        let dark = c.tick(nowNanos: 200 * s, fullWake: false)
        let full = c.tick(nowNanos: 201 * s, fullWake: true)
        #expect(dark == nil)
        #expect(full != nil)
    }

    /// After any power-on, a full-wake tick promotes at once.
    @Test func aFullTickAfterADarkPowerOnPromotesAtOnce() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 100 * s)
        _ = c.poweredOn(fullWake: false, nowNanos: 200 * s)
        let full = c.tick(nowNanos: 201 * s, fullWake: true)
        #expect(full != nil)
    }

    /// The app's wake ends the pause at any point of the table, exactly once.
    @Test func theAppsWakeEndsThePauseAtAnyPointOnce() {
        let steps: [(inout SleepPauseClock) -> Void] = [
            { _ in },
            { _ = $0.tick(nowNanos: 101 * 1_000_000_000, fullWake: true) },
            { _ = $0.tick(nowNanos: 101 * 1_000_000_000, fullWake: false) },
            { _ = $0.poweredOn(fullWake: false, nowNanos: 101 * 1_000_000_000) },
            { _ = $0.poweredOn(fullWake: nil, nowNanos: 101 * 1_000_000_000) },
        ]
        for (i, step) in steps.enumerated() {
            var c = SleepPauseClock()
            c.pause(nowNanos: 100 * s)
            step(&c)
            let first = c.wake()
            let second = c.wake()
            #expect(first != nil, "step \(i)")
            #expect(second == nil, "step \(i)")
            #expect(!c.isPaused, "step \(i)")
        }
    }

    // MARK: - Round 4

    /// N1: over a night, Power Naps must not add up to the 5 min DarkWake bound — that would end the
    /// pause inside a later DarkWake, with the devices off (item 11's false alarm).
    @Test func darkTimeDoesNotAccumulateAcrossPowerNaps() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 0)
        _ = c.poweredOn(fullWake: false, nowNanos: 1_000 * s)        // Power Nap 1
        let nap1 = c.tick(nowNanos: 1_200 * s, fullWake: false)      // 200 s of it
        c.pause(nowNanos: 1_201 * s)                                 // back to sleep (IOKit will-sleep)
        _ = c.poweredOn(fullWake: false, nowNanos: 5_000 * s)        // Power Nap 2
        let nap2 = c.tick(nowNanos: 5_200 * s, fullWake: false)      // 200 s: 400 s in total
        #expect(nap1 == nil)
        #expect(nap2 == nil, "each nap is bounded on its own: 200 s < 300 s")
        #expect(c.isPaused)
    }

    /// A new cycle keeps the mic work that waited for the wake (a coreaudiod restart in an earlier nap).
    @Test func aNewCycleKeepsDeferredMicWork() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 0)
        _ = c.deferMicWork(.serviceRestart)
        c.pause(nowNanos: 10 * s)
        let resumed = c.wake()
        #expect(resumed == [.serviceRestart])
    }

    /// M3: the log (and the X1 check) tells a promotion from an expiry.
    @Test func eachWakeSaysWhatEndedThePause() {
        var promoted = SleepPauseClock()
        promoted.pause(nowNanos: 0)
        _ = promoted.tick(nowNanos: 1 * s, fullWake: false)
        _ = promoted.tick(nowNanos: 2 * s, fullWake: true)
        #expect(promoted.lastWakeReason == .promotedToFullWake)

        var expired = SleepPauseClock()
        expired.pause(nowNanos: 0)
        _ = expired.poweredOn(fullWake: false, nowNanos: 1 * s)
        _ = expired.tick(nowNanos: 301 * s, fullWake: false)
        #expect(expired.lastWakeReason == .expired)

        var implicit = SleepPauseClock()
        implicit.pause(nowNanos: 0)
        _ = implicit.poweredOn(fullWake: true, nowNanos: 1 * s)
        #expect(implicit.lastWakeReason == .fullWakePowerOn)

        var app = SleepPauseClock()
        app.pause(nowNanos: 0)
        _ = app.wake()
        #expect(app.lastWakeReason == .appWake)
    }

    // MARK: - Round 5 item 2: only the system's will-sleep starts a new cycle

    /// The app's "sleep" handled after IOKit's power-on must not wipe the running clock.
    @Test func aLateAppSleepDuringAPauseIsIgnored() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 0, from: .system)
        _ = c.poweredOn(fullWake: false, nowNanos: 100 * s)
        c.pause(nowNanos: 150 * s, from: .app)                 // late: must not reset the clock
        let due = c.tick(nowNanos: 400 * s, fullWake: false)   // 300 s after the power-on
        #expect(due != nil)
    }

    @Test func theAppsSleepStartsACycleWhenNoneIsRunning() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 0, from: .app)
        #expect(c.isPaused)
    }

    @Test func theSystemsWillSleepAlwaysStartsANewCycle() {
        var c = SleepPauseClock()
        c.pause(nowNanos: 0, from: .app)
        _ = c.poweredOn(fullWake: false, nowNanos: 100 * s)
        c.pause(nowNanos: 150 * s, from: .system)              // back to sleep: a new cycle
        let old = c.tick(nowNanos: 400 * s, fullWake: false)
        #expect(old == nil, "the first cycle's clock is gone")
    }
}
