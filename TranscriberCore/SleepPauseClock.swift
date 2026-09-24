import Foundation

/// Bounds the liveness pause for sleep (H2 council, A-I7 / B-M6). "sleep" pauses both monitors and
/// only "wake" re-armed them, so a lost or reordered wake left both tracks unjudged for the rest of the
/// call. The pause now expires after `expirySeconds` of AWAKE time: fed uptime (mach_absolute_time),
/// which does not advance while the machine sleeps, so a real sleep of any length never expires it —
/// only a wake that never came does. On expiry the helper resumes exactly as if woken.
public struct SleepPauseClock: Equatable, Sendable {
    public static let expirySeconds: Double = 30

    /// When the pause began, in uptime nanoseconds; `nil` = not paused.
    private var pausedAtNanos: UInt64?

    public init() {}

    public var isPaused: Bool { pausedAtNanos != nil }

    /// A duplicate "sleep" keeps the first stamp, so it cannot push the expiry back.
    public mutating func pause(nowNanos: UInt64) {
        if pausedAtNanos == nil { pausedAtNanos = nowNanos }
    }

    /// The wake arrived.
    public mutating func resume() {
        pausedAtNanos = nil
    }

    /// Every awake tick: true once, when the pause has lasted `expirySeconds` — the wake was lost.
    public mutating func tick(nowNanos: UInt64) -> Bool {
        guard let at = pausedAtNanos, nowNanos > at, Double(nowNanos - at) / 1e9 >= Self.expirySeconds else { return false }
        pausedAtNanos = nil
        return true
    }
}
