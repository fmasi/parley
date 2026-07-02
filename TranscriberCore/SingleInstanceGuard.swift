import Foundation

/// Decides whether a just-launched process should exit because another instance already owns the
/// singleton. Pure logic (no AppKit) so it is unit-testable; the app supplies the live instance list
/// from `NSRunningApplication`.
///
/// Why this exists: the app installs a crash-recovery LaunchAgent with `KeepAlive` at startup, and a
/// `KeepAlive` agent is started by launchd the moment it loads — so a GUI launch plus the agent's
/// load would bring up TWO instances (competing menu-bar apps / recorders). This guard makes any
/// duplicate self-exit. Crash recovery is unaffected: after a real crash no instance is running, so
/// the relaunched process passes the guard.
public enum SingleInstanceGuard {

    public struct Instance: Sendable, Equatable {
        public let pid: Int32
        public let launchDate: Date?
        public init(pid: Int32, launchDate: Date?) {
            self.pid = pid
            self.launchDate = launchDate
        }
    }

    /// Whether THIS process should terminate. Policy: keep exactly one survivor — the
    /// earliest-launched instance, tie-broken by lowest pid — and terminate every other. `instances`
    /// must include self; a single entry never terminates. The decision is deterministic, so when two
    /// instances evaluate the same list, both pick the same survivor and only the non-survivor exits.
    /// A `nil` launchDate sorts last (treated as launched-later) so a dated foreground instance is
    /// preferred over one whose launch time is unavailable.
    public static func shouldTerminate(selfPid: Int32, instances: [Instance]) -> Bool {
        guard instances.count > 1 else { return false }
        guard let survivor = instances.min(by: isEarlier) else { return false }
        return survivor.pid != selfPid
    }

    /// Strict ordering: earlier launchDate wins; equal/absent dates fall back to lower pid. A present
    /// date always beats an absent one.
    private static func isEarlier(_ a: Instance, _ b: Instance) -> Bool {
        switch (a.launchDate, b.launchDate) {
        case let (x?, y?):
            return x == y ? a.pid < b.pid : x < y
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return a.pid < b.pid
        }
    }
}
