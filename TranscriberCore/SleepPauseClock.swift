import Foundation

/// The helper's sleep pause (H2 council, A-I7 / B-M6; round 2 items 11, 13, 18; round 3 A/B). "sleep"
/// pauses both liveness monitors, and once only the app's "wake" re-armed them, so a lost or reordered
/// wake left both tracks unjudged for the rest of the call. A pure state machine:
///
/// | event                          | effect                                                          |
/// |--------------------------------|-----------------------------------------------------------------|
/// | `pause`                        | a NEW cycle: `sawDark = false`, `poweredOn = false`, no clock — |
/// |                                | also when already paused: each sleep is bounded on its own, so  |
/// |                                | Power Naps never add up (round 4 N1); deferred mic work stays   |
/// | tick reading full wake         | wake ONLY IF `sawDark || poweredOn` since the pause (a real     |
/// |                                | dark-to-full promotion); else ignored — the ~5 s "darkwakelinger"|
/// |                                | before a clamshell sleep reads full-wake while going TO sleep   |
/// | tick reading DarkWake          | `sawDark = true`                                                |
/// | power-on, full wake            | wake now (implicit wake)                                        |
/// | power-on, DarkWake             | `poweredOn = true`, LONG clock (`darkPowerOnExpirySeconds`)     |
/// | power-on, unclassified         | `poweredOn = true`, 30 s clock (`expirySeconds`)                |
/// | the app's wake                 | wake now                                                        |
/// | a clock runs out (awake time)  | wake                                                            |
///
/// Every wake happens once (a second is a no-op, round 2 item 13), and once a power-on has been seen
/// every path ends in a bounded expiry: nothing means "never". Clocks count awake uptime
/// (mach_absolute_time does not advance while asleep). Without power notifications, the 30 s clock
/// starts at the pause (round 1's behaviour). Mic work that arrives while paused (a coreaudiod restart)
/// is kept and handed to the wake, so no mic reopen — and no reopen deadline — runs across the sleep.
public struct SleepPauseClock: Equatable, Sendable {
    public enum MicWork: Hashable, Sendable {
        /// coreaudiod restarted: re-register the mic's listeners and reopen it.
        case serviceRestart
    }

    /// What ended the last pause — for the log, and the X1 check (round 4 M3).
    public enum WakeReason: String, Equatable, Sendable {
        case appWake = "the app's wake"
        case fullWakePowerOn = "a full-wake power-on"
        case promotedToFullWake = "a promotion to full wake"
        case expired = "the bound expired"
    }

    /// After an unclassified power-on (or the pause, without power notifications).
    public static let expirySeconds: Double = 30
    /// After a power-on that read DarkWake: a Power Nap stays paused this long, then the pause ends
    /// anyway rather than never (round 3 B).
    public static let darkPowerOnExpirySeconds: Double = 300

    private var paused = false
    private var sawDark = false
    private var poweredOn = false
    /// When the pause ends by expiry, in uptime nanoseconds; `nil` = no clock running.
    private var expiresAtNanos: UInt64?
    private var pendingMicWork: Set<MicWork> = []
    public private(set) var lastWakeReason: WakeReason?

    public init() {}

    public var isPaused: Bool { paused }

    /// Sleep (the app's, or IOKit's will-sleep). Always a NEW cycle (round 4 N1): a will-sleep while
    /// already paused — the machine going back to sleep after a Power Nap — resets the cycle's state and
    /// clock, so every wake is bounded on its own. Mic work deferred in an earlier nap still waits for
    /// the wake. `expiryStartsNow`: power notifications are unavailable, so the only bound is uptime
    /// from here.
    public mutating func pause(nowNanos: UInt64, expiryStartsNow: Bool = false) {
        if !paused { pendingMicWork = [] }
        paused = true
        sawDark = false
        poweredOn = false
        expiresAtNanos = nil
        if expiryStartsNow { startClock(seconds: Self.expirySeconds, nowNanos: nowNanos) }
    }

    /// The app's wake. nil when not paused — a second wake (implicit, then the app's) does nothing.
    /// Otherwise the pause ends, and the mic work that waited for it is returned.
    public mutating func wake() -> Set<MicWork>? {
        end(.appWake)
    }

    private mutating func end(_ reason: WakeReason) -> Set<MicWork>? {
        guard paused else { return nil }
        lastWakeReason = reason
        paused = false
        expiresAtNanos = nil
        defer { pendingMicWork = [] }
        return pendingMicWork
    }

    /// IOKit's power-on. `fullWake`: true = the graphics capability is up (a user wake), false = a
    /// DarkWake, nil = could not tell.
    public mutating func poweredOn(fullWake: Bool?, nowNanos: UInt64) -> Set<MicWork>? {
        guard paused else { return nil }
        switch fullWake {
        case true?:
            return end(.fullWakePowerOn)
        case false?:
            poweredOn = true
            startClock(seconds: Self.darkPowerOnExpirySeconds, nowNanos: nowNanos)
            return nil
        case nil:
            poweredOn = true
            startClock(seconds: Self.expirySeconds, nowNanos: nowNanos)
            return nil
        }
    }

    /// Every awake tick while paused, with the current capability reading.
    public mutating func tick(nowNanos: UInt64, fullWake: Bool?) -> Set<MicWork>? {
        guard paused else { return nil }
        switch fullWake {
        case true? where sawDark || poweredOn: return end(.promotedToFullWake)   // a real dark-to-full promotion
        case false?: sawDark = true
        default: break                                         // darkwakelinger, or unreadable
        }
        guard let at = expiresAtNanos, nowNanos >= at else { return nil }
        return end(.expired)
    }

    /// Mic work that must not run while paused. True = kept for the wake; false = awake, run it now.
    public mutating func deferMicWork(_ work: MicWork) -> Bool {
        guard paused else { return false }
        pendingMicWork.insert(work)
        return true
    }

    /// Within a cycle a clock only ever gets SHORTER: a later, longer one never pushes it back.
    private mutating func startClock(seconds: Double, nowNanos: UInt64) {
        let at = nowNanos + UInt64(seconds * 1e9)
        expiresAtNanos = min(expiresAtNanos ?? at, at)
    }
}
