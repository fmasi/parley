import Foundation

/// Race-free single-instance guard for the app (#109).
///
/// Why this exists: the crash-recovery `LaunchAgent` (`KeepAlive = {SuccessfulExit: false}`) makes
/// `launchd` spawn a *duplicate* copy of the app at load time while a user-launched instance is
/// already running — `launchd` starts a KeepAlive job on load regardless of the dict form (the dict
/// only scopes *restart-after-exit*, not the initial launch). The duplicate must detect the original
/// and exit cleanly.
///
/// Why a file lock and not `NSRunningApplication`: an earlier version compared the running-app list
/// (oldest instance wins). That races during launch — a launchd-spawned duplicate runs its check
/// inside `App.init()`, *before* the first instance has registered with LaunchServices, so it sees an
/// empty peer list and both instances survive (device-confirmed #109). `flock` closes the race: it's
/// atomic in the kernel and independent of any app-level registration. Exactly one concurrently
/// launching instance acquires the exclusive lock; the rest observe it held and yield.
///
/// Interaction with crash recovery: the lock is tied to the open file description, so the kernel
/// releases it automatically when the holder exits — including a crash. A crash-recovery relaunch
/// therefore re-acquires the now-free lock and proceeds. A duplicate that yields exits with status 0,
/// which `KeepAlive = {SuccessfulExit: false}` does NOT relaunch, so there is no respawn loop.
public enum SingleInstanceGuard {

    /// Result of trying to take the single-instance lock.
    public enum LockOutcome: Equatable {
        /// This instance now holds the lock. Keep `fd` open for the whole process lifetime (never
        /// close it) — closing it, or letting it be collected, releases the lock.
        case acquired(fd: Int32)
        /// Another live instance already holds the lock. The caller should exit cleanly (status 0).
        case heldByOther
        /// The lock file could not be opened (e.g. missing parent directory, permissions). The
        /// caller should proceed UNGUARDED — failing open is better than refusing to launch.
        case unavailable
    }

    /// Attempt to take an exclusive, non-blocking `flock` on the file at `path`, creating it if
    /// needed. See the type doc for why this is race-free where an `NSRunningApplication` scan is not.
    public static func acquireLock(at path: String) -> LockOutcome {
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        if fd < 0 { return .unavailable }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return .acquired(fd: fd)
        }
        // Only EWOULDBLOCK means "a live instance holds it, yield". Any other errno is unexpected;
        // fail open (proceed unguarded) rather than wedge the app shut on a transient lock error.
        let heldByOther = (errno == EWOULDBLOCK)
        close(fd)
        return heldByOther ? .heldByOther : .unavailable
    }
}
