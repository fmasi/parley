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
        /// yield on it). See `LaunchAgentManager.handOverToJob` and `crashProtectionAction` above.
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
        if case .healthy = state { return nil }
        // Without the lock nothing is repaired or handed over (C2 round 5), so the lock IS the problem,
        // whatever the state (L3 fix round 1, item 7).
        guard holdsInstanceLock else { return noLockMessage }
        switch state {
        case .healthy: return nil
        case .missing, .notLoaded, .stalePath:
            return "Crash protection is off — if Parley crashes mid-recording it will not relaunch. Quit and reopen Parley to repair it."
        case .loadedButNotThisProcess:
            // "Quit and reopen" is not honest here (fix round 2, item 3): reopening from Finder
            // just recreates this same state, since it still isn't the process launchd's KeepAlive
            // tracks. The hand-over (`LaunchAgentManager.handOverToJob`, gated by
            // `crashProtectionAction`) re-enables protection on its own once not recording.
            return "Crash protection is off — Parley will re-enable it automatically the next time you're not recording."
        }
    }

    /// No single-instance lock (`SingleInstanceGuard.LockOutcome.unavailable`): often persistent — the
    /// data folder can't be opened or locked — so reopening is not promised. Says what is wrong.
    public static let noLockMessage = "Crash protection is off: Parley couldn’t lock its data folder, so it can’t turn crash relaunch on. Check that ~/Library/Application Support/Parley is on a local disk you can write to."

    /// The hand-over can't happen (this is launchd's own job, or kickstart failed `maxHandOverAttempts`
    /// times): nothing will re-enable it on its own.
    public static let handOverImpossibleMessage = "Crash protection is off — Parley couldn’t hand over to its crash-relaunch job. Quit and reopen Parley to turn it back on."

    /// Kickstart attempts per process before giving up on the hand-over (L3 fix round 1, item 5).
    public static let maxHandOverAttempts = 3

    /// How long open Parley windows may defer the hand-over while idle before the row says so (L round
    /// 3): never silently off because some window stays up.
    public static let windowDeferralLimit: TimeInterval = 15 * 60

    public static let windowsBlockingMessage = "Crash protection is waiting for you to close Parley’s windows — until then, if Parley crashes mid-recording it will not relaunch."

    /// A recording under a process that has not handed over to its crash-relaunch job (final review A-I2): the hand-over
    /// (an exit) cannot happen under it, and it may last hours.
    public static let recordingUnprotectedMessage = "Crash protection is off for this recording — if Parley crashes now it will not relaunch or resume it. It turns back on after the recording ends."

    /// Whether a window defers the hand-over (L rounds 3-4): on screen, a real size, at any level up to
    /// and including `maxLevel` (the app passes `NSWindow.Level.popUpMenu`, so the menu-bar dropdown
    /// panel counts). Only the status item's own button window is excluded, by its class name.
    public static func windowDefersHandOver(isVisible: Bool, width: Double, height: Double,
                                            level: Int, maxLevel: Int, className: String) -> Bool {
        guard isVisible, width > 0, height > 0, level <= maxLevel else { return false }
        return !className.contains("StatusBar")
    }

    /// What the app does with a crash-protection verdict (L3 fix round 1, item 6). No case schedules a
    /// timer in a steady state: `.deferUntilIdle` waits for the transition to idle, `.retryAfter`
    /// re-checks once, `.alarm` never retries.
    public enum CrashProtectionAction: Equatable, Sendable {
        /// Clear the `crashProtectionOff` alarm.
        case healthy
        /// Post-recording work or a Parley window is in flight: re-check on the transition to idle, and
        /// once more after `recheckAfter` seconds when set. `message`: the row to show meanwhile (a
        /// window deferral past `windowDeferralLimit`), nil = no row.
        case deferUntilIdle(message: String?, recheckAfter: TimeInterval?)
        /// Persist `lastHandOverAt`, `kickstart -k`, re-check "idle" after it returns, then `exit(0)`.
        case handOver
        /// The hand-over cooldown is running: re-check ONCE when it expires. `message`: the row to show
        /// meanwhile (only once a hand-over has actually failed).
        case retryAfter(seconds: TimeInterval, message: String?)
        /// The sticky row; no automatic retry.
        case alarm(String)
    }

    /// `isBusy`: a recording, its transcription or post-recording work. `isRecording`: a recording is running — the
    /// hand-over cannot happen under it, so the row says so (final review A-I2). `anyWindowVisible`: any Parley
    /// window on screen — Settings, the menu-bar panel, a panel — a hand-over (an exit) would close it
    /// mid-edit (L2/L4 fix round 2, item 6). `windowDeferredFor`: how long windows alone (not work) have
    /// deferred it so far; past `windowDeferralLimit` the row says so (L round 3).
    public static func crashProtectionAction(state: State, holdsInstanceLock: Bool, isLaunchdJob: Bool, isBusy: Bool,
                                             isRecording: Bool,
                                             anyWindowVisible: Bool, windowDeferredFor: TimeInterval, lastHandOverAt: Date?,
                                             now: Date, failedHandOvers: Int) -> CrashProtectionAction {
        switch state {
        case .healthy:
            return .healthy
        case .loadedButNotThisProcess:
            guard holdsInstanceLock else { return .alarm(noLockMessage) }
            guard !isLaunchdJob, failedHandOvers < maxHandOverAttempts else { return .alarm(handOverImpossibleMessage) }
            // A recording may last hours and the hand-over (an exit) cannot happen under it: say so, once (final review A-I2).
            if isRecording { return .deferUntilIdle(message: recordingUnprotectedMessage, recheckAfter: nil) }
            // Other work (transcription, post-recording work, a panel preparing) defers without a row or a limit.
            if isBusy { return .deferUntilIdle(message: nil, recheckAfter: nil) }
            if anyWindowVisible {
                return windowDeferredFor >= windowDeferralLimit
                    ? .deferUntilIdle(message: windowsBlockingMessage, recheckAfter: nil)
                    : .deferUntilIdle(message: nil, recheckAfter: windowDeferralLimit - windowDeferredFor)
            }
            if let lastHandOverAt, now.timeIntervalSince(lastHandOverAt) < handOverCooldown {
                let remaining = handOverCooldown - now.timeIntervalSince(lastHandOverAt)
                return .retryAfter(seconds: remaining,
                                   message: failedHandOvers > 0 ? userMessage(for: state, holdsInstanceLock: true) : nil)
            }
            return .handOver
        case .missing, .notLoaded, .stalePath:
            // verifyAndRepair returns the state AFTER repair: this means repair failed (or was skipped
            // without the lock).
            return .alarm(userMessage(for: state, holdsInstanceLock: holdsInstanceLock) ?? handOverImpossibleMessage)
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

    // MARK: - Hand-over cooldown (owner-ruled robustness gap, fix round 1, item 4)

    /// Minimum time between two `.handOverToJob` attempts, to avoid a kickstart loop. The rest of the
    /// hand-over guard (never while busy or recording, never by the launchd job itself, never without
    /// the single-instance lock) is decided by `crashProtectionAction`.
    public static let handOverCooldown: TimeInterval = 30
}
