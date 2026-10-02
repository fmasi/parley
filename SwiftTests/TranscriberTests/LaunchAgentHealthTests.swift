import Foundation
import Testing
@testable import TranscriberCore

/// L11: the plist existed (mtime Sep 17, path correct) but `launchctl print gui/501/eu.fmasi.parley`
/// said "Could not find service" — Quit's unload removed the job and left the file, and launch
/// only checked the file. Crash protection was off all day, including during the 16:00 recording.
@Suite struct LaunchAgentHealthTests {
    let exe = "/Applications/Parley.app/Contents/MacOS/Parley"

    @Test func loadedWithCurrentPathIsHealthy() {
        #expect(LaunchAgentHealth.assess(plistProgramPath: exe, executablePath: exe, loaded: true) == .healthy)
        #expect(LaunchAgentHealth.action(for: .healthy) == .none)
    }

    @Test func missingPlistInstallsAndBootstraps() {
        let s = LaunchAgentHealth.assess(plistProgramPath: nil, executablePath: exe, loaded: false)
        #expect(s == .missing(staleLoadedJob: false))
        #expect(LaunchAgentHealth.action(for: s) == .installAndBootstrap)
    }

    /// Fix round 1, item 3: the plist is gone, but launchd still has A job loaded pointing at some
    /// OTHER program — that leftover must be booted out before a fresh one can be bootstrapped.
    @Test func missingPlistWithAStaleLoadedJobBootsOutFirst() {
        let s = LaunchAgentHealth.assess(
            plistProgramPath: nil, executablePath: exe, loaded: true,
            loadedProgramPath: "/Users/x/Downloads/Parley.app/Contents/MacOS/Parley"
        )
        #expect(s == .missing(staleLoadedJob: true))
        #expect(LaunchAgentHealth.action(for: s) == .bootoutInstallAndBootstrap)
    }

    /// Fix round 1, item 3 (the critical case): the plist is gone, but launchd's loaded job points
    /// at THIS SAME program — very likely this very process. An unconditional bootout here would
    /// SIGTERM the app at launch. Must NOT be treated as stale.
    @Test func missingPlistWithTheLoadedJobPointingAtUsIsNotStale() {
        let s = LaunchAgentHealth.assess(
            plistProgramPath: nil, executablePath: exe, loaded: true, loadedProgramPath: exe
        )
        #expect(s == .missing(staleLoadedJob: false))
        #expect(LaunchAgentHealth.action(for: s) == .installAndBootstrap)
    }

    /// The incident: file present, job gone.
    @Test func presentButNotLoadedBootstraps() {
        let s = LaunchAgentHealth.assess(plistProgramPath: exe, executablePath: exe, loaded: false)
        #expect(s == .notLoaded)
        #expect(LaunchAgentHealth.action(for: s) == .bootstrap)
    }

    /// The app moved (a Sparkle update into a new path, or a dev build): a loaded job pointing at
    /// the old binary relaunches the wrong app or nothing.
    @Test func stalePathIsRewrittenEvenWhenLoaded() {
        let old = "/Users/x/Downloads/Parley.app/Contents/MacOS/Parley"
        let s = LaunchAgentHealth.assess(plistProgramPath: old, executablePath: exe, loaded: true)
        #expect(s == .stalePath(found: old))
        #expect(LaunchAgentHealth.action(for: s) == .rewriteAndBootstrap)
    }

    // MARK: - loadedButNotThisProcess (fix round 1, item 4)

    @Test func loadedWithMatchingPidIsHealthy() {
        let s = LaunchAgentHealth.assess(
            plistProgramPath: exe, executablePath: exe, loaded: true, loadedPID: 4242, currentPID: 4242
        )
        #expect(s == .healthy)
    }

    /// Loaded, path matches, but the pid launchd reports is not THIS process: the running app was
    /// launched some other way (Finder, a Sparkle relaunch, quit-and-reopen) and is not the job
    /// launchd's KeepAlive tracks — a crash of THIS process would not be relaunched.
    @Test func loadedWithADifferentPidIsNotThisProcess() {
        let s = LaunchAgentHealth.assess(
            plistProgramPath: exe, executablePath: exe, loaded: true, loadedPID: 4242, currentPID: 9999
        )
        #expect(s == .loadedButNotThisProcess)
        #expect(LaunchAgentHealth.action(for: s) == .handOverToJob)
    }

    /// No pid reported at all counts as "not this process" too.
    @Test func loadedWithNoPidReportedIsNotThisProcess() {
        let s = LaunchAgentHealth.assess(
            plistProgramPath: exe, executablePath: exe, loaded: true, loadedPID: nil, currentPID: 9999
        )
        #expect(s == .loadedButNotThisProcess)
    }

    /// Fix round 2, item 1c: the on-disk plist matches, but launchd's ACTUALLY loaded job (e.g.
    /// loaded before an update overwrote the plist in place) points elsewhere. That is stalePath —
    /// never a pid-based hand-over, which would just kickstart the WRONG binary.
    @Test func loadedJobPointingElsewhereIsStalePathEvenWhenThePlistMatches() {
        let staleProgram = "/Users/x/Downloads/Parley.app/Contents/MacOS/Parley"
        let s = LaunchAgentHealth.assess(
            plistProgramPath: exe, executablePath: exe, loaded: true,
            loadedProgramPath: staleProgram, loadedPID: 1, currentPID: 9999
        )
        #expect(s == .stalePath(found: staleProgram))
        #expect(LaunchAgentHealth.action(for: s) == .rewriteAndBootstrap)
    }

    /// Fix round 2, item 3: reopening from Finder just recreates `loadedButNotThisProcess` (it's
    /// still not the launchd job) — "Quit and reopen" is not honest advice here. Parley re-enables
    /// crash protection on its own via the hand-over, the next time it isn't recording.
    @Test func loadedButNotThisProcessMessageDoesNotSayQuitAndReopen() {
        let message = LaunchAgentHealth.userMessage(for: .loadedButNotThisProcess, holdsInstanceLock: true)
        #expect(message?.contains("Quit and reopen") == false)
        #expect(message?.contains("automatically") == true)
    }

    /// L3 (C2 final, wiring 5; L3 fix round 1, item 7): without the single-instance lock this process
    /// never hands over or repairs, so "re-enables automatically" would be a false promise — and the
    /// lock failure is often persistent, so reopening is not promised either. Say what is wrong.
    @Test func withoutTheLockTheMessageSaysWhatIsWrongAndPromisesNothing() {
        for state: LaunchAgentHealth.State in [.loadedButNotThisProcess, .notLoaded, .missing(staleLoadedJob: false), .stalePath(found: "/x")] {
            let message = LaunchAgentHealth.userMessage(for: state, holdsInstanceLock: false) ?? ""
            #expect(message == LaunchAgentHealth.noLockMessage)
        }
        #expect(!LaunchAgentHealth.noLockMessage.contains("automatically"))
        #expect(!LaunchAgentHealth.noLockMessage.localizedCaseInsensitiveContains("reopen")
                && !LaunchAgentHealth.noLockMessage.contains("open it again"))
        #expect(LaunchAgentHealth.noLockMessage.contains("data folder"))
    }

    @Test func onlyUnhealthyStatesHaveAUserMessage() {
        for lock in [true, false] {
            #expect(LaunchAgentHealth.userMessage(for: .healthy, holdsInstanceLock: lock) == nil)
            #expect(LaunchAgentHealth.userMessage(for: .missing(staleLoadedJob: false), holdsInstanceLock: lock)?.contains("Crash protection") == true)
            #expect(LaunchAgentHealth.userMessage(for: .missing(staleLoadedJob: true), holdsInstanceLock: lock)?.contains("Crash protection") == true)
            #expect(LaunchAgentHealth.userMessage(for: .notLoaded, holdsInstanceLock: lock)?.contains("Crash protection") == true)
            #expect(LaunchAgentHealth.userMessage(for: .stalePath(found: "/x"), holdsInstanceLock: lock)?.contains("Crash protection") == true)
            #expect(LaunchAgentHealth.userMessage(for: .loadedButNotThisProcess, holdsInstanceLock: lock)?.contains("Crash protection") == true)
        }
    }

    // MARK: - L3 fix round 1: the crash-protection decision (items 3-6)

    @Test func crashProtectionDecisionTable() {
        let now = Date(timeIntervalSince1970: 1000)
        func act(_ state: LaunchAgentHealth.State, lock: Bool = true, job: Bool = false, busy: Bool = false, recording: Bool = false,
                 window: Bool = false, windowDeferredFor: TimeInterval = 0, last: Date? = nil,
                 failed: Int = 0) -> LaunchAgentHealth.CrashProtectionAction {
            LaunchAgentHealth.crashProtectionAction(state: state, holdsInstanceLock: lock, isLaunchdJob: job, isBusy: busy,
                                                    isRecording: recording,
                                                    anyWindowVisible: window, windowDeferredFor: windowDeferredFor,
                                                    lastHandOverAt: last, now: now, failedHandOvers: failed)
        }
        let limit = LaunchAgentHealth.windowDeferralLimit
        let auto = LaunchAgentHealth.userMessage(for: .loadedButNotThisProcess, holdsInstanceLock: true)
        #expect(act(.healthy) == .healthy)
        #expect(act(.healthy, lock: false, busy: true) == .healthy)
        #expect(act(.loadedButNotThisProcess) == .handOver)
        // Any post-recording work or panel: no row, re-check on the transition to idle.
        #expect(act(.loadedButNotThisProcess, busy: true) == .deferUntilIdle(message: nil, recheckAfter: nil))
        // L2/L4 fix round 2, item 6: ANY visible Parley window (Settings, the menu-bar panel, a panel).
        #expect(act(.loadedButNotThisProcess, window: true) == .deferUntilIdle(message: nil, recheckAfter: limit))
        // L round 3, item 1: the window deferral is bounded — never silent. Past 15 min while idle, the
        // row says why crash protection is still off, and it keeps waiting for the windows to close.
        #expect(limit == 15 * 60)
        #expect(act(.loadedButNotThisProcess, window: true, windowDeferredFor: limit - 60)
                == .deferUntilIdle(message: nil, recheckAfter: 60))
        #expect(act(.loadedButNotThisProcess, window: true, windowDeferredFor: limit)
                == .deferUntilIdle(message: LaunchAgentHealth.windowsBlockingMessage, recheckAfter: nil))
        // A recording or post-recording work is not a window: it may legitimately last hours.
        #expect(act(.loadedButNotThisProcess, busy: true, window: true, windowDeferredFor: 3 * limit)
                == .deferUntilIdle(message: nil, recheckAfter: nil))
        // Final review A-I2: a RECORDING under a process that could not hand over runs without crash relaunch — said, once:
        // the row, whatever the windows; post-recording work alone (busy, not recording) still says nothing.
        #expect(act(.loadedButNotThisProcess, busy: true, recording: true)
                == .deferUntilIdle(message: LaunchAgentHealth.recordingUnprotectedMessage, recheckAfter: nil))
        #expect(act(.loadedButNotThisProcess, busy: true, recording: true, window: true, windowDeferredFor: 3 * limit)
                == .deferUntilIdle(message: LaunchAgentHealth.recordingUnprotectedMessage, recheckAfter: nil))
        #expect(act(.healthy, busy: true, recording: true) == .healthy, "protected: nothing to say")
        #expect(LaunchAgentHealth.recordingUnprotectedMessage.contains("Crash protection is off for this recording"))
        // Cooldown: ONE re-check when it expires; no row until a hand-over has actually failed.
        #expect(act(.loadedButNotThisProcess, last: now - 10) == .retryAfter(seconds: 20, message: nil))
        #expect(act(.loadedButNotThisProcess, last: now - 10, failed: 1) == .retryAfter(seconds: 20, message: auto))
        #expect(act(.loadedButNotThisProcess, last: now - 30, failed: 2) == .handOver)
        // Capped: after 3 failed kickstarts, the permanent copy and no more retries.
        #expect(act(.loadedButNotThisProcess, failed: LaunchAgentHealth.maxHandOverAttempts) == .alarm(LaunchAgentHealth.handOverImpossibleMessage))
        // The launchd job never hands over to itself: permanent, never "re-enables automatically".
        #expect(act(.loadedButNotThisProcess, job: true) == .alarm(LaunchAgentHealth.handOverImpossibleMessage))
        #expect(!LaunchAgentHealth.handOverImpossibleMessage.contains("automatically"))
        // No lock: say so; nothing is retried.
        #expect(act(.loadedButNotThisProcess, lock: false) == .alarm(LaunchAgentHealth.noLockMessage))
        #expect(act(.loadedButNotThisProcess, lock: false, busy: true) == .alarm(LaunchAgentHealth.noLockMessage))
        // Repair failed (or skipped without the lock).
        #expect(act(.notLoaded) == .alarm(LaunchAgentHealth.userMessage(for: .notLoaded, holdsInstanceLock: true)!))
        #expect(act(.stalePath(found: "/x"), lock: false) == .alarm(LaunchAgentHealth.noLockMessage))
    }

    /// L round 3, item 1 + round 4, item 3: a real, on-screen window at any level up to and including
    /// the pop-up menu level defers the hand-over — the menu-bar dropdown panel included. Never a
    /// zero-size helper window, one ordered out, one above that level, or the status item's own button.
    @Test func realWindowsUpToTheMenuLevelDeferTheHandOver() {
        let popUpMenu = 101   // NSWindow.Level.popUpMenu.rawValue; the app passes the real one
        func counts(visible: Bool = true, width: Double = 400, height: Double = 300, level: Int = 0,
                    className: String = "NSPanel") -> Bool {
            LaunchAgentHealth.windowDefersHandOver(isVisible: visible, width: width, height: height,
                                                   level: level, maxLevel: popUpMenu, className: className)
        }
        #expect(counts())
        #expect(counts(level: 3), "floating")
        #expect(counts(level: popUpMenu, className: "SwiftUI.MenuBarExtraWindow"), "the menu-bar dropdown panel")
        #expect(!counts(level: popUpMenu + 1), "above menus: overlays, screen savers")
        #expect(!counts(visible: false))
        #expect(!counts(width: 0))
        #expect(!counts(height: 0))
        #expect(!counts(level: 25, className: "NSStatusBarWindow"), "the status item's own button window")
    }

    // MARK: - Quit (L3, C2 final wiring 4)

    /// `uninstall()` boots the job out, which SIGTERMs whichever process launchd runs as the job.
    /// Without the single-instance lock that may be another live instance, possibly recording.
    @Test func quitUninstallsTheAgentOnlyWithTheSingleInstanceLock() {
        #expect(LaunchAgentHealth.shouldUninstallOnQuit(holdsInstanceLock: true))
        #expect(!LaunchAgentHealth.shouldUninstallOnQuit(holdsInstanceLock: false))
    }

}

/// Final review AF-10: one crash-protection check at a time, and a check asked for while one runs is never DROPPED. The
/// recording's start re-check (A-I2) can arrive while a check is inside the hand-over's kickstart; dropped, that check
/// would find the app busy, stay, and the recording would run unprotected with no row.
@MainActor
@Suite struct CrashProtectionSerialCheckTests {
    @Test func aCheckAskedForWhileOneRunsRunsOnceAfterIt() async {
        let checks = LaunchAgentHealth.SerialCheck()
        var runs = 0, concurrent = 0
        await checks.run {
            runs += 1
            guard runs == 1 else { return }
            // Two asks arrive while the first check is still running (the hook, a cooldown retry): neither runs now.
            await checks.run { concurrent += 1 }
            await checks.run { concurrent += 1 }
            #expect(checks.isRunning)
        }
        #expect(concurrent == 0, "never two checks at once")
        #expect(runs == 2, "the asks were not dropped: the check ran ONCE more after the running one, however many asked")
        #expect(!checks.isRunning)
    }

    @Test func aCheckWithNoAskMeanwhileRunsOnce() async {
        let checks = LaunchAgentHealth.SerialCheck()
        var runs = 0
        await checks.run { runs += 1 }
        await checks.run { runs += 1 }
        #expect(runs == 2 && !checks.isRunning, "each ends; the next runs on its own")
    }

    /// A failed hand-over decides again (one retry after the cooldown, or the capped row) — from inside the running check.
    @Test func theRunningCheckCanAskToRunAgain() async {
        let checks = LaunchAgentHealth.SerialCheck()
        var runs = 0
        await checks.run {
            runs += 1
            if runs < 3 { checks.runAgainAfterThis() }
        }
        #expect(runs == 3 && !checks.isRunning)
    }
}

/// #236, #237: what a crash-protection verdict does to the row that is already up.
@MainActor
@Suite struct CrashProtectionRowTests {
    private typealias Health = LaunchAgentHealth
    private let recording = LaunchAgentHealth.CrashProtectionAction.deferUntilIdle(
        message: LaunchAgentHealth.recordingUnprotectedMessage, recheckAfter: nil)

    private func rowMessage(_ state: AppState) -> String? { state.activeAlarms[.crashProtectionOff]?.message }

    /// #237: the "close Parley's windows" row is up and Record is pressed. The row must say "off for this recording".
    @Test func aRecordingStartingUnderTheWindowsRowRewordsIt() {
        #expect(Health.rowChange(for: recording, currentMessage: Health.windowsBlockingMessage)
                == .revise(old: Health.windowsBlockingMessage, new: Health.recordingUnprotectedMessage))

        let state = AppState()
        let t0 = Date(timeIntervalSince1970: 1000)
        state.showCrashProtection(.deferUntilIdle(message: Health.windowsBlockingMessage, recheckAfter: nil), now: t0)
        #expect(rowMessage(state) == Health.windowsBlockingMessage)
        state.showCrashProtection(recording, now: t0 + 60)
        #expect(rowMessage(state) == Health.recordingUnprotectedMessage, "the row says the new reason, and only it")
        #expect(state.activeAlarms[.crashProtectionOff]?.raisedAt == t0, "the same row re-worded, not a new one")
    }

    /// The same for every reason: a row that promised "automatically" must not keep saying so once the hand-over is given up.
    @Test func aRowUpWithAnotherReasonIsRewordedWhateverTheVerdict() throws {
        let automatic = try #require(Health.userMessage(for: .loadedButNotThisProcess, holdsInstanceLock: true))
        #expect(Health.rowChange(for: .alarm(Health.handOverImpossibleMessage), currentMessage: automatic)
                == .revise(old: automatic, new: Health.handOverImpossibleMessage))
        #expect(Health.rowChange(for: .retryAfter(seconds: 20, message: automatic), currentMessage: Health.recordingUnprotectedMessage)
                == .revise(old: Health.recordingUnprotectedMessage, new: automatic))
        #expect(Health.rowChange(for: .deferUntilIdle(message: Health.windowsBlockingMessage, recheckAfter: nil),
                                 currentMessage: Health.recordingUnprotectedMessage)
                == .revise(old: Health.recordingUnprotectedMessage, new: Health.windowsBlockingMessage))
    }

    @Test func aRowThatAlreadySaysItIsKept() {
        #expect(Health.rowChange(for: recording, currentMessage: Health.recordingUnprotectedMessage) == .keep)
        #expect(Health.rowChange(for: .alarm(Health.noLockMessage), currentMessage: Health.noLockMessage) == .keep)
    }

    @Test func noRowYetIsRaisedAndAVerdictWithNothingToSayLeavesTheRowAlone() {
        #expect(Health.rowChange(for: recording, currentMessage: nil) == .raise(Health.recordingUnprotectedMessage))
        #expect(Health.rowChange(for: .alarm(Health.noLockMessage), currentMessage: nil) == .raise(Health.noLockMessage))
        #expect(Health.rowChange(for: .retryAfter(seconds: 20, message: Health.noLockMessage), currentMessage: nil)
                == .raise(Health.noLockMessage))
        for current in [nil, Health.windowsBlockingMessage] {
            #expect(Health.rowChange(for: .handOver, currentMessage: current) == .keep)
            #expect(Health.rowChange(for: .retryAfter(seconds: 20, message: nil), currentMessage: current) == .keep)
            #expect(Health.rowChange(for: .healthy, currentMessage: current) == .clear)
            #expect(Health.rowChange(for: .deferUntilIdle(message: nil, recheckAfter: 60), currentMessage: current) == .clear)
        }
    }

    /// #236: the check run as the recording ends finds transcription in flight, and that verdict clears the recording's
    /// row. (The app runs that check on the transition out of recording: `TranscriberApp`, not testable here.)
    @Test func theRecordingsRowGoesWhenTheCheckRunsDuringTranscription() {
        let state = AppState()
        state.showCrashProtection(recording)
        #expect(rowMessage(state) == Health.recordingUnprotectedMessage)
        let transcribing = Health.crashProtectionAction(
            state: .loadedButNotThisProcess, holdsInstanceLock: true, isLaunchdJob: false, isBusy: true, isRecording: false,
            anyWindowVisible: false, windowDeferredFor: 0, lastHandOverAt: nil, now: Date(), failedHandOvers: 0)
        state.showCrashProtection(transcribing)
        #expect(rowMessage(state) == nil)
    }
}
