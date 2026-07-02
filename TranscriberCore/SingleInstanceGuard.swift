import Foundation

/// Decides whether a just-started app instance should yield (exit) because another instance of the
/// same app is already running.
///
/// Why this exists (#109): the crash-recovery `LaunchAgent` (`KeepAlive = {SuccessfulExit: false}`)
/// causes `launchd` to spawn a *duplicate* copy of the app at load time while a user-launched
/// instance is already running — `launchd` starts a KeepAlive job on load regardless of the dict
/// form (the dict only scopes *restart-after-exit*, not the initial launch). Rather than depend on
/// subtle, version-dependent launchd semantics, the app runs this guard at startup and the duplicate
/// exits cleanly. A clean (status 0) exit is NOT an "unsuccessful exit", so `KeepAlive` will not
/// relaunch the yielded copy — no respawn loop. A genuine crash still recovers correctly: the crashed
/// process is gone, so the relaunched instance sees no rival and does not yield.
///
/// The decision is a **strict total order** over instances — by launch date when both are known and
/// differ, otherwise by PID (unique among concurrently-running processes). This guarantees exactly
/// one survivor (the global minimum) even if several duplicates evaluate the guard simultaneously and
/// each sees all the others: every instance except the single oldest yields.
public enum SingleInstanceGuard {

    /// Identity of a running instance, as read from `NSRunningApplication` at the call site.
    public struct Instance: Sendable, Equatable {
        public let pid: Int32
        public let launchDate: Date?
        public init(pid: Int32, launchDate: Date?) {
            self.pid = pid
            self.launchDate = launchDate
        }
    }

    /// Returns `true` if `me` should exit because at least one strictly-older instance is running.
    ///
    /// - Parameters:
    ///   - me: this process's identity.
    ///   - others: the OTHER running instances of the same app (must exclude `me`).
    public static func shouldYield(me: Instance, others: [Instance]) -> Bool {
        others.contains { isOlder($0, than: me) }
    }

    /// Strict total order used to pick the single survivor. `lhs` is "older" than `rhs` when it
    /// launched earlier; ties (equal or unknown dates) fall back to the unique PID so the order is
    /// always total and every instance agrees on who wins.
    static func isOlder(_ lhs: Instance, than rhs: Instance) -> Bool {
        if let l = lhs.launchDate, let r = rhs.launchDate, l != r {
            return l < r
        }
        return lhs.pid < rhs.pid
    }
}
