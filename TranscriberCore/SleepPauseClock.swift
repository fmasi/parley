import Foundation

/// The helper's sleep pause (H2 council, A-I7 / B-M6; round 2 items 11, 13, 18). "sleep" pauses both
/// liveness monitors, and once only the app's "wake" re-armed them, so a lost or reordered wake left both
/// tracks unjudged for the rest of the call. Now the pause ends at the FIRST of:
/// - the app's wake;
/// - IOKit's power-on when it is a confirmed FULL wake (the graphics capability is up): an implicit
///   wake, idempotent with the app's;
/// - a tick that sees a DarkWake promoted to a full wake (the promotion sends no second power-on);
/// - `expirySeconds` of awake uptime after a power-on the helper could NOT classify — or, when power
///   notifications are unavailable, after the pause itself (round 1's behaviour).
/// A confirmed DarkWake / Power Nap never ends the pause and never starts the clock: its devices may be
/// off, and judging them would raise false alarms. Uptime (mach_absolute_time) does not advance while
/// asleep. Mic work that arrives while paused (a coreaudiod restart) is kept and handed to the wake, so
/// no mic reopen — and no reopen deadline — runs across the sleep.
public struct SleepPauseClock: Equatable, Sendable {
    public enum MicWork: Hashable, Sendable {
        /// coreaudiod restarted: re-register the mic's listeners and reopen it.
        case serviceRestart
    }

    public static let expirySeconds: Double = 30

    private var paused = false
    /// When the expiry clock started, in uptime nanoseconds; `nil` = not running.
    private var expiryStartedAtNanos: UInt64?
    private var pendingMicWork: Set<MicWork> = []

    public init() {}

    public var isPaused: Bool { paused }

    /// Sleep (the app's, or IOKit's will-sleep). A repeat keeps the first stamp. `expiryStartsNow`: power
    /// notifications are unavailable, so the only bound is uptime from here.
    public mutating func pause(nowNanos: UInt64, expiryStartsNow: Bool = false) {
        if !paused {
            paused = true
            expiryStartedAtNanos = nil
            pendingMicWork = []
        }
        if expiryStartsNow, expiryStartedAtNanos == nil { expiryStartedAtNanos = nowNanos }
    }

    /// The app's wake. nil when not paused — a second wake (implicit, then the app's) does nothing.
    /// Otherwise the pause ends, and the mic work that waited for it is returned.
    public mutating func wake() -> Set<MicWork>? {
        guard paused else { return nil }
        paused = false
        expiryStartedAtNanos = nil
        defer { pendingMicWork = [] }
        return pendingMicWork
    }

    /// IOKit's power-on. `fullWake`: true = the graphics capability is up (a user wake), false = a
    /// DarkWake, nil = could not tell. A confirmed full wake wakes now; an unclassified one starts the
    /// expiry clock; a DarkWake does nothing.
    public mutating func poweredOn(fullWake: Bool?, nowNanos: UInt64) -> Set<MicWork>? {
        guard paused else { return nil }
        switch fullWake {
        case true?: return wake()
        case nil:
            if expiryStartedAtNanos == nil { expiryStartedAtNanos = nowNanos }
            return nil
        case false?: return nil
        }
    }

    /// Every awake tick while paused, with the current capability reading: a promotion to a full wake,
    /// or the expiry clock running out, ends the pause.
    public mutating func tick(nowNanos: UInt64, fullWake: Bool?) -> Set<MicWork>? {
        guard paused else { return nil }
        if fullWake == true { return wake() }
        guard let at = expiryStartedAtNanos, nowNanos > at, Double(nowNanos - at) / 1e9 >= Self.expirySeconds else { return nil }
        return wake()
    }

    /// Mic work that must not run while paused. True = kept for the wake; false = awake, run it now.
    public mutating func deferMicWork(_ work: MicWork) -> Bool {
        guard paused else { return false }
        pendingMicWork.insert(work)
        return true
    }
}
