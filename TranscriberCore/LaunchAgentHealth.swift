import Foundation

/// Pure judgement of the crash-relaunch LaunchAgent (L11). `isInstalled()` used to mean "the plist
/// file exists"; launchd's opinion is what relaunches the app, so the job must be LOADED and must
/// point at the binary that is running.
public enum LaunchAgentHealth {
    public enum State: Equatable, Sendable {
        /// No plist on disk. `staleLoadedJob` is true only when launchd nonetheless still has the
        /// job loaded AND it points at a DIFFERENT program than this one — that leftover must be
        /// booted out before a fresh plist can be bootstrapped. When false (no job loaded, or the
        /// loaded job points at THIS program — very likely this very process), it must NOT be
        /// booted out: an unconditional bootout would SIGTERM the app at launch. (Review finding,
        /// fix round 1, item 3.)
        case missing(staleLoadedJob: Bool)
        case stalePath(found: String)
        case notLoaded
        /// Loaded, path matches, but the loaded job's pid is not this process's pid (or launchd
        /// reports no pid at all): the app was launched some other way (Finder, a Sparkle relaunch,
        /// quit-and-reopen) and is not the job launchd's KeepAlive tracks, so a crash of THIS
        /// process would not be relaunched. (Owner-ruled robustness gap, fix round 1, item 4.)
        case loadedButNotThisProcess
        case healthy
    }

    public enum Action: Equatable, Sendable {
        case none
        case installAndBootstrap
        /// `.missing(staleLoadedJob: true)`: bootout the stale leftover job first.
        case bootoutInstallAndBootstrap
        case rewriteAndBootstrap
        case bootstrap
        /// `.loadedButNotThisProcess`: `launchctl kickstart -k` launchd's own copy; on success, THIS
        /// process releases the single-instance lock and exits 0 (fix round 3, item 5 — it does not
        /// merely "yield": see `SingleInstancePolicy` for why B must wait for the lock rather than
        /// yield on it). See `LaunchAgentManager.handOverToJob` and `shouldAttemptHandOver` below.
        case handOverToJob
    }

    public static func assess(
        plistProgramPath: String?,
        executablePath: String,
        loaded: Bool,
        loadedProgramPath: String? = nil,
        loadedPID: pid_t? = nil,
        currentPID: pid_t? = nil
    ) -> State {
        guard let plistProgramPath else {
            let staleLoadedJob = loaded && loadedProgramPath != nil && loadedProgramPath != executablePath
            return .missing(staleLoadedJob: staleLoadedJob)
        }
        if plistProgramPath != executablePath { return .stalePath(found: plistProgramPath) }
        guard loaded else { return .notLoaded }
        // The on-disk plist matches, but launchd's ACTUALLY loaded job might not — e.g. loaded from
        // a stale plist before an update overwrote the file in place. That is ALSO stalePath: never
        // a pid-based hand-over decision for a job that would just restart the WRONG binary.
        // (Fix round 2, item 1c.)
        if let loadedProgramPath, loadedProgramPath != executablePath { return .stalePath(found: loadedProgramPath) }
        // Only judged when the caller supplies a pid to compare against (production always does —
        // see `LaunchAgentManager.verifyAndRepair` — but existing call sites that only care about
        // path/loaded-ness can omit it and get the pre-fix-round-1 behaviour).
        if let currentPID, loadedPID != currentPID { return .loadedButNotThisProcess }
        return .healthy
    }

    public static func action(for state: State) -> Action {
        switch state {
        case .healthy: return .none
        case .missing(let staleLoadedJob): return staleLoadedJob ? .bootoutInstallAndBootstrap : .installAndBootstrap
        case .stalePath: return .rewriteAndBootstrap
        case .notLoaded: return .bootstrap
        case .loadedButNotThisProcess: return .handOverToJob
        }
    }

    /// The sticky row's text; nil when there is nothing to say. `holdsInstanceLock` (deliberately no
    /// default, like `verifyAndRepair`): whether this process holds the single-instance lock, which
    /// decides whether it can ever hand over and so what it may honestly promise.
    public static func userMessage(for state: State, holdsInstanceLock: Bool) -> String? {
        switch state {
        case .healthy: return nil
        case .missing, .notLoaded, .stalePath:
            return "Crash protection is off — if Parley crashes mid-recording it will not relaunch. Quit and reopen Parley to repair it."
        case .loadedButNotThisProcess:
            guard holdsInstanceLock else {
                // No lock, no hand-over (`shouldAttemptHandOver`): nothing will re-enable it on its
                // own. A fresh launch can take the lock and hand over (L3, C2 final wiring 5).
                return "Crash protection is off. Quit Parley and open it again to turn it back on."
            }
            // "Quit and reopen" is not honest here (fix round 2, item 3): reopening from Finder
            // just recreates this same state, since it still isn't the process launchd's KeepAlive
            // tracks. The hand-over (`LaunchAgentManager.handOverToJob`, gated by
            // `shouldAttemptHandOver`) re-enables protection on its own once not recording.
            return "Crash protection is off — Parley will re-enable it automatically the next time you're not recording."
        }
    }

    /// Whether Quit may remove the LaunchAgent (`LaunchAgentManager.uninstall`, whose `bootout`
    /// SIGTERMs whichever process launchd runs as the job). Only with the single-instance lock: without
    /// it another live instance may be that job, and may be recording (L3, C2 final wiring 4).
    public static func shouldUninstallOnQuit(holdsInstanceLock: Bool) -> Bool { holdsInstanceLock }

    /// Log-safe name: `stalePath` carries a filesystem path, which is never logged `.public`.
    public static func logName(for state: State) -> String {
        switch state {
        case .healthy: return "healthy"
        case .missing(let staleLoadedJob): return staleLoadedJob ? "missing(staleLoadedJob)" : "missing"
        case .stalePath: return "stalePath"
        case .notLoaded: return "notLoaded"
        case .loadedButNotThisProcess: return "loadedButNotThisProcess"
        }
    }

    // MARK: - Hand-over guard (owner-ruled robustness gap, fix round 1, item 4)

    /// Minimum time between two `.handOverToJob` attempts, to avoid a kickstart loop.
    public static let handOverCooldown: TimeInterval = 30

    /// Whether it is safe to attempt `.handOverToJob` right now. Pure; the caller (L3) supplies the
    /// facts — this type has no idea whether a recording is in progress or a kickstart was already
    /// tried. Never during a recording (killing this process mid-recording would lose audio still
    /// buffered here), never in CLI mode (there is no menu-bar app instance to hand over to, and a
    /// one-shot CLI invocation is not what KeepAlive is meant to protect), never when THIS process
    /// already IS the launchd job (fix round 3, item 4 — it would be handing over to itself), never
    /// without the single-instance lock (fix round 5, item 1 — `kickstart -k` kills the running
    /// job, which is only safe when the lock proves no other instance can be recording; an
    /// unguarded process, lock unavailable, has no such proof), and never twice within
    /// `handOverCooldown` of the last attempt.
    public static func shouldAttemptHandOver(isRecording: Bool, isCLI: Bool, isLaunchdJob: Bool, holdsInstanceLock: Bool, lastHandOverAt: Date?, now: Date) -> Bool {
        guard !isRecording, !isCLI, !isLaunchdJob, holdsInstanceLock else { return false }
        if let lastHandOverAt, now.timeIntervalSince(lastHandOverAt) < handOverCooldown { return false }
        return true
    }
}
