import Foundation

/// Decides what a launching process should do when the single-instance lock is already held —
/// the A→B hand-over protocol for `LaunchAgentManager.handOverToJob` (fix round 2, item 2).
///
/// "kickstart then yield" (round 1's plan, as documented at the time) would leave NO instance
/// running: A still holds the flock when launchd starts B; B's yield-on-duplicate check sees the
/// lock held and exits 0 (`SuccessfulExit: false`, so launchd does not relaunch a clean exit);
/// then A exits too, having handed off to a process that just quit. The fix: the launchd-spawned
/// job (B) WAITS for A to release the lock instead of yielding; every OTHER duplicate launch still
/// yields immediately, exactly as before.
///
/// Pure; the caller (L3) detects `isLaunchdJob` at the call site (e.g. the environment's
/// `XPC_SERVICE_NAME` equals `LaunchAgentManager.label`, or an equivalent check) and
/// `lockHeldByOther` from the existing single-instance lock attempt, and supplies both here. This
/// type does not touch the lock, the environment, or any app file itself.
public enum SingleInstancePolicy: Equatable, Sendable {
    case proceed
    case yield
    case waitForLock(seconds: TimeInterval)

    /// How long the launchd job (B) waits for the outgoing process (A) to release the lock during
    /// a hand-over before giving up.
    public static let lockWaitTimeout: TimeInterval = 10

    public static func decide(isLaunchdJob: Bool, lockHeldByOther: Bool) -> SingleInstancePolicy {
        guard lockHeldByOther else { return .proceed }
        return isLaunchdJob ? .waitForLock(seconds: lockWaitTimeout) : .yield
    }
}
