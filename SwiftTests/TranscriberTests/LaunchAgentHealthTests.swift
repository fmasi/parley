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

    @Test func onlyUnhealthyStatesHaveAUserMessage() {
        #expect(LaunchAgentHealth.userMessage(for: .healthy) == nil)
        #expect(LaunchAgentHealth.userMessage(for: .missing(staleLoadedJob: false))?.contains("Crash protection") == true)
        #expect(LaunchAgentHealth.userMessage(for: .missing(staleLoadedJob: true))?.contains("Crash protection") == true)
        #expect(LaunchAgentHealth.userMessage(for: .notLoaded)?.contains("Crash protection") == true)
        #expect(LaunchAgentHealth.userMessage(for: .stalePath(found: "/x"))?.contains("Crash protection") == true)
        #expect(LaunchAgentHealth.userMessage(for: .loadedButNotThisProcess)?.contains("Crash protection") == true)
    }

    // MARK: - shouldAttemptHandOver (fix round 1, item 4 guards)

    @Test func handOverIsAllowedWhenIdleAndNotCLIWithNoPriorAttempt() {
        #expect(LaunchAgentHealth.shouldAttemptHandOver(isRecording: false, isCLI: false, lastHandOverAt: nil, now: .init(timeIntervalSince1970: 1000)))
    }

    @Test func handOverIsNeverAttemptedWhileRecording() {
        #expect(!LaunchAgentHealth.shouldAttemptHandOver(isRecording: true, isCLI: false, lastHandOverAt: nil, now: .init(timeIntervalSince1970: 1000)))
    }

    @Test func handOverIsNeverAttemptedInCLIMode() {
        #expect(!LaunchAgentHealth.shouldAttemptHandOver(isRecording: false, isCLI: true, lastHandOverAt: nil, now: .init(timeIntervalSince1970: 1000)))
    }

    @Test func handOverIsSkippedWithinTheCooldownOfTheLastAttempt() {
        let now = Date(timeIntervalSince1970: 1000)
        let last = now.addingTimeInterval(-(LaunchAgentHealth.handOverCooldown - 1))
        #expect(!LaunchAgentHealth.shouldAttemptHandOver(isRecording: false, isCLI: false, lastHandOverAt: last, now: now))
    }

    @Test func handOverIsAllowedOnceTheCooldownHasElapsed() {
        let now = Date(timeIntervalSince1970: 1000)
        let last = now.addingTimeInterval(-LaunchAgentHealth.handOverCooldown)
        #expect(LaunchAgentHealth.shouldAttemptHandOver(isRecording: false, isCLI: false, lastHandOverAt: last, now: now))
    }
}
