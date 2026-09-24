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
        #expect(s == .missing)
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

    @Test func onlyUnhealthyStatesHaveAUserMessage() {
        #expect(LaunchAgentHealth.userMessage(for: .healthy) == nil)
        #expect(LaunchAgentHealth.userMessage(for: .notLoaded)?.contains("Crash protection") == true)
        #expect(LaunchAgentHealth.userMessage(for: .stalePath(found: "/x"))?.contains("Crash protection") == true)
    }
}
