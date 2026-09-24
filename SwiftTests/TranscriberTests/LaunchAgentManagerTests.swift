import Testing
import Foundation
@testable import TranscriberCore

struct LaunchAgentManagerTests {
    private let exe = "/Applications/Parley.app/Contents/MacOS/Parley"

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchAgentManagerTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - generatePlist

    @Test func generatesPlistWithCorrectLabel() {
        let plist = LaunchAgentManager.generatePlist(executablePath: "/Applications/Transcriber.app/Contents/MacOS/Parley")
        #expect(plist.contains("eu.fmasi.parley"))
        #expect(plist.contains("ProgramArguments"))
        #expect(plist.contains("/Applications/Transcriber.app/Contents/MacOS/Parley"))
        #expect(!plist.contains("BundlePath"))
        #expect(plist.contains("KeepAlive"))
        #expect(plist.contains("ProcessType"))
        #expect(plist.contains("Interactive"))
    }

    @Test func keepAliveScopedToCrashesOnly() {
        // The LaunchAgent must NOT use the boolean <true/> form of KeepAlive.
        // That form makes `launchctl load -w` spawn a duplicate instance whenever the
        // app is launched via LaunchServices (`open`) and the agent is loaded right after,
        // producing two menu-bar icons. The dict + SuccessfulExit:false form scopes
        // relaunch to crash recovery only.
        let plist = LaunchAgentManager.generatePlist(executablePath: "/Applications/Transcriber.app/Contents/MacOS/Parley")
        #expect(plist.contains("<key>SuccessfulExit</key>"))
        #expect(plist.contains("<false/>"))
        // Sanity: the boolean form must not slip back in.
        let keepAliveBoolean = "<key>KeepAlive</key>\n            <true/>"
        #expect(!plist.contains(keepAliveBoolean))
    }

    /// Fix round 2, item 3: an unescaped "&" (or <, >, ", ') in the path breaks the plist's XML.
    @Test func generatePlistEscapesXMLSpecialCharactersInThePath() {
        let pathWithAmpersand = "/Applications/Parley & Friends.app/Contents/MacOS/Parley"
        let plist = LaunchAgentManager.generatePlist(executablePath: pathWithAmpersand)
        #expect(plist.contains("Parley &amp; Friends"))
        #expect(!plist.contains("Parley & Friends"))
    }

    /// `programPath(inPlist:)` must unescape symmetrically, or a freshly-written plist would look
    /// "stale" against the raw `executablePath` on every subsequent `verifyAndRepair` call.
    @Test func programPathRoundTripsAnEscapedAmpersand() {
        let pathWithAmpersand = "/Applications/Parley & Friends.app/Contents/MacOS/Parley"
        let plist = LaunchAgentManager.generatePlist(executablePath: pathWithAmpersand)
        #expect(LaunchAgentManager.programPath(inPlist: plist) == pathWithAmpersand)
    }

    // MARK: - install

    @Test func installWritesPlistFile() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        try await LaunchAgentManager.install(
            executablePath: "/Applications/Transcriber.app/Contents/MacOS/Parley",
            launchAgentsDir: dir,
            loadAgent: false
        )

        let plistURL = dir.appendingPathComponent(LaunchAgentManager.plistName)
        #expect(FileManager.default.fileExists(atPath: plistURL.path))

        let content = try String(contentsOf: plistURL, encoding: .utf8)
        #expect(content.contains("eu.fmasi.parley"))
        #expect(content.contains("ProgramArguments"))
        #expect(content.contains("/Applications/Transcriber.app/Contents/MacOS/Parley"))
        #expect(content.contains("KeepAlive"))
    }

    // MARK: - uninstall

    @Test func uninstallRemovesPlistFile() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // First install
        try await LaunchAgentManager.install(
            executablePath: "/Applications/Transcriber.app/Contents/MacOS/Parley",
            launchAgentsDir: dir,
            loadAgent: false
        )

        let plistURL = dir.appendingPathComponent(LaunchAgentManager.plistName)
        #expect(FileManager.default.fileExists(atPath: plistURL.path))

        // Now uninstall
        await LaunchAgentManager.uninstall(launchAgentsDir: dir, unloadAgent: false)

        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
    }

    // MARK: - isInstalled

    @Test func isInstalledReturnsFalseWhenMissing() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        #expect(!LaunchAgentManager.isInstalled(launchAgentsDir: dir))
    }

    @Test func isInstalledReturnsTrueAfterInstall() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        try await LaunchAgentManager.install(
            executablePath: "/Applications/Transcriber.app/Contents/MacOS/Parley",
            launchAgentsDir: dir,
            loadAgent: false
        )

        #expect(LaunchAgentManager.isInstalled(launchAgentsDir: dir))
    }

    // MARK: - programPath(inPlist:)

    @Test func programPathIsParsedFromTheGeneratedPlist() {
        let plist = LaunchAgentManager.generatePlist(executablePath: "/Applications/Parley.app/Contents/MacOS/Parley")
        #expect(LaunchAgentManager.programPath(inPlist: plist) == "/Applications/Parley.app/Contents/MacOS/Parley")
        #expect(LaunchAgentManager.programPath(inPlist: "<plist><dict></dict></plist>") == nil)
    }

    // MARK: - loadedProgramPath(inPrintOutput:) / loadedPID(inPrintOutput:) — fix round 1, item 4

    private let samplePrintOutput = """
    gui/501/eu.fmasi.parley = {
    \tactive count = 1
    \tpath = /Users/fmasi/Library/LaunchAgents/eu.fmasi.parley.plist
    \ttype = LaunchAgent
    \tstate = running

    \tprogram = /Applications/Parley.app/Contents/MacOS/Parley
    \truns = 1
    \tpid = 4242
    }
    """

    @Test func loadedProgramPathIsParsedFromPrintOutput() {
        #expect(LaunchAgentManager.loadedProgramPath(inPrintOutput: samplePrintOutput) == "/Applications/Parley.app/Contents/MacOS/Parley")
        #expect(LaunchAgentManager.loadedProgramPath(inPrintOutput: "") == nil)
    }

    /// Fix round 2, item 1a: the old regex captured `(\S+)`, truncating any path containing a
    /// space — "/Applications/Parley 2.app/.../Parley" became "/Applications/Parley".
    @Test func loadedProgramPathWithASpaceIsNotTruncated() {
        let output = "program = /Applications/Parley 2.app/Contents/MacOS/Parley\npid = 4242\n"
        #expect(LaunchAgentManager.loadedProgramPath(inPrintOutput: output) == "/Applications/Parley 2.app/Contents/MacOS/Parley")
    }

    @Test func loadedPIDIsParsedFromPrintOutput() {
        #expect(LaunchAgentManager.loadedPID(inPrintOutput: samplePrintOutput) == 4242)
        #expect(LaunchAgentManager.loadedPID(inPrintOutput: "") == nil)
    }

    // MARK: - verifyAndRepair command sequences (fix round 1, items 1 + 2)

    private func gui(_ uid: uid_t) -> String { "gui/\(uid)" }
    private func job(_ uid: uid_t) -> String { "gui/\(uid)/\(LaunchAgentManager.label)" }

    @Test func healthyRunsNothingBeyondTheInitialPrint() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let uid: uid_t = 501
        try await LaunchAgentManager.install(executablePath: exe, launchAgentsDir: dir, loadAgent: false)

        let runner = RecordingLaunchctlRunner(responses: [
            "print": [LaunchctlResult(status: 0, output: "program = \(exe)\npid = 4242\n")]
        ])
        let state = await LaunchAgentManager.verifyAndRepair(
            executablePath: exe, launchAgentsDir: dir, uid: uid, currentPID: 4242, runner: runner
        )
        #expect(state == .healthy)
        let calls = await runner.calls
        #expect(calls == [["print", job(uid)]])
    }

    /// Item 1 [CRITICAL]: `enable` must run immediately before EVERY `bootstrap` — a probe job
    /// proved `bootstrap` alone fails ("5: Input/output error") after `unload -w`'s disabled
    /// override, while `enable` then `bootstrap` succeeds.
    @Test func missingWithNoStaleJobEnablesThenBootstraps() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let uid: uid_t = 501
        let plistPath = dir.appendingPathComponent(LaunchAgentManager.plistName).path

        let runner = RecordingLaunchctlRunner(responses: [
            "print": [LaunchctlResult(status: 1), LaunchctlResult(status: 0, output: "program = \(exe)\npid = 4242\n")]
        ])
        let state = await LaunchAgentManager.verifyAndRepair(
            executablePath: exe, launchAgentsDir: dir, uid: uid, currentPID: 4242, runner: runner
        )
        #expect(state == .healthy)
        let calls = await runner.calls
        #expect(calls == [
            ["print", job(uid)],
            ["enable", job(uid)],
            ["bootstrap", gui(uid), plistPath],
            ["print", job(uid)],
        ])
        // The plist was actually written (the repair's "write" step).
        let written = try String(contentsOfFile: plistPath, encoding: .utf8)
        #expect(LaunchAgentManager.programPath(inPlist: written) == exe)
    }

    /// Item 3: the plist is gone AND launchd's loaded job points at a DIFFERENT program — that
    /// leftover must be booted out first, or bootstrap fails with "already loaded".
    @Test func missingWithAStaleLoadedJobBootsOutBeforeEnableAndBootstrap() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let uid: uid_t = 501
        let plistPath = dir.appendingPathComponent(LaunchAgentManager.plistName).path
        let staleProgram = "/Users/x/Downloads/Parley.app/Contents/MacOS/Parley"

        let runner = RecordingLaunchctlRunner(responses: [
            "print": [
                LaunchctlResult(status: 0, output: "program = \(staleProgram)\npid = 1\n"),
                LaunchctlResult(status: 0, output: "program = \(exe)\npid = 4242\n"),
            ]
        ])
        let state = await LaunchAgentManager.verifyAndRepair(
            executablePath: exe, launchAgentsDir: dir, uid: uid, currentPID: 4242, runner: runner
        )
        #expect(state == .healthy)
        let calls = await runner.calls
        #expect(calls == [
            ["print", job(uid)],
            ["bootout", job(uid)],
            ["enable", job(uid)],
            ["bootstrap", gui(uid), plistPath],
            ["print", job(uid)],
        ])
    }

    /// Item 3 (the critical case): the plist is gone but launchd's loaded job points at THIS SAME
    /// program — very likely this very process. Must NOT bootout (that would SIGTERM the app).
    @Test func missingWithTheLoadedJobPointingAtUsNeverBootsOut() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let uid: uid_t = 501
        let plistPath = dir.appendingPathComponent(LaunchAgentManager.plistName).path

        let runner = RecordingLaunchctlRunner(responses: [
            "print": [
                LaunchctlResult(status: 0, output: "program = \(exe)\npid = 4242\n"),
                LaunchctlResult(status: 0, output: "program = \(exe)\npid = 4242\n"),
            ]
        ])
        let state = await LaunchAgentManager.verifyAndRepair(
            executablePath: exe, launchAgentsDir: dir, uid: uid, currentPID: 4242, runner: runner
        )
        #expect(state == .healthy)
        let calls = await runner.calls
        #expect(calls == [
            ["print", job(uid)],
            ["enable", job(uid)],
            ["bootstrap", gui(uid), plistPath],
            ["print", job(uid)],
        ])
    }

    @Test func notLoadedEnablesThenBootstraps() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let uid: uid_t = 501
        let plistPath = dir.appendingPathComponent(LaunchAgentManager.plistName).path
        try await LaunchAgentManager.install(executablePath: exe, launchAgentsDir: dir, loadAgent: false)

        let runner = RecordingLaunchctlRunner(responses: [
            "print": [LaunchctlResult(status: 1), LaunchctlResult(status: 0, output: "program = \(exe)\npid = 4242\n")]
        ])
        let state = await LaunchAgentManager.verifyAndRepair(
            executablePath: exe, launchAgentsDir: dir, uid: uid, currentPID: 4242, runner: runner
        )
        #expect(state == .healthy)
        let calls = await runner.calls
        #expect(calls == [
            ["print", job(uid)],
            ["enable", job(uid)],
            ["bootstrap", gui(uid), plistPath],
            ["print", job(uid)],
        ])
    }

    @Test func stalePathBootsOutWritesEnablesThenBootstraps() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let uid: uid_t = 501
        let plistPath = dir.appendingPathComponent(LaunchAgentManager.plistName).path
        let old = "/Users/x/Downloads/Parley.app/Contents/MacOS/Parley"
        try await LaunchAgentManager.install(executablePath: old, launchAgentsDir: dir, loadAgent: false)

        let runner = RecordingLaunchctlRunner(responses: [
            "print": [
                LaunchctlResult(status: 0, output: "program = \(old)\npid = 1\n"),
                LaunchctlResult(status: 0, output: "program = \(exe)\npid = 4242\n"),
            ]
        ])
        let state = await LaunchAgentManager.verifyAndRepair(
            executablePath: exe, launchAgentsDir: dir, uid: uid, currentPID: 4242, runner: runner
        )
        #expect(state == .healthy)
        let calls = await runner.calls
        #expect(calls == [
            ["print", job(uid)],
            ["bootout", job(uid)],
            ["enable", job(uid)],
            ["bootstrap", gui(uid), plistPath],
            ["print", job(uid)],
        ])
        // The plist was rewritten to the CURRENT path (the repair's "write" step).
        let written = try String(contentsOfFile: plistPath, encoding: .utf8)
        #expect(LaunchAgentManager.programPath(inPlist: written) == exe)
    }

    @Test func loadedButNotThisProcessRunsNoRepairBeyondTheInitialPrint() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let uid: uid_t = 501
        try await LaunchAgentManager.install(executablePath: exe, launchAgentsDir: dir, loadAgent: false)

        let runner = RecordingLaunchctlRunner(responses: [
            "print": [LaunchctlResult(status: 0, output: "program = \(exe)\npid = 1\n")]
        ])
        let state = await LaunchAgentManager.verifyAndRepair(
            executablePath: exe, launchAgentsDir: dir, uid: uid, currentPID: 9999, runner: runner
        )
        #expect(state == .loadedButNotThisProcess)
        let calls = await runner.calls
        #expect(calls == [["print", job(uid)]])
    }

    /// Fix round 2, item 3 (a "realistic" test, not placeholder pid 1): launchd's KeepAlive job is
    /// still running from before a crash (pid 41213); the user then double-clicked Parley.app in
    /// Finder, producing a second, unrelated process (pid 52217) that isn't the job launchd tracks.
    @Test func verifyAndRepairReportsLoadedButNotThisProcessAfterARealisticFinderRelaunch() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let uid: uid_t = 501
        try await LaunchAgentManager.install(executablePath: exe, launchAgentsDir: dir, loadAgent: false)

        let runner = RecordingLaunchctlRunner(responses: [
            "print": [LaunchctlResult(status: 0, output: "program = \(exe)\npid = 41213\n")]
        ])
        let state = await LaunchAgentManager.verifyAndRepair(
            executablePath: exe, launchAgentsDir: dir, uid: uid, currentPID: 52217, runner: runner
        )
        #expect(state == .loadedButNotThisProcess)
        let calls = await runner.calls
        #expect(calls == [["print", job(uid)]])
    }

    /// Fix round 2, item 1a (the reported regression, end to end): a space in the install path used
    /// to truncate the parsed `program =`, so it never matched the executablePath comparison,
    /// `staleLoadedJob` came out true, and `verifyAndRepair` booted out the job that WAS this
    /// process — SIGTERMing it after a crash relaunch.
    @Test func missingWithASpaceInThePathAndTheLoadedJobBeingUsNeverBootsOut() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let uid: uid_t = 501
        let exeWithSpace = "/Applications/Parley 2.app/Contents/MacOS/Parley"
        let plistPath = dir.appendingPathComponent(LaunchAgentManager.plistName).path

        let runner = RecordingLaunchctlRunner(responses: [
            "print": [
                LaunchctlResult(status: 0, output: "program = \(exeWithSpace)\npid = 4242\n"),
                LaunchctlResult(status: 0, output: "program = \(exeWithSpace)\npid = 4242\n"),
            ]
        ])
        let state = await LaunchAgentManager.verifyAndRepair(
            executablePath: exeWithSpace, launchAgentsDir: dir, uid: uid, currentPID: 4242, runner: runner
        )
        #expect(state == .healthy)
        let calls = await runner.calls
        #expect(!calls.contains { $0.first == "bootout" })
        #expect(calls == [
            ["print", job(uid)],
            ["enable", job(uid)],
            ["bootstrap", gui(uid), plistPath],
            ["print", job(uid)],
        ])
    }

    /// Fix round 2, item 1b: an absolute safety net independent of any state classification — never
    /// bootout the job whose pid IS this process, no matter what the program-path comparison says
    /// (adversarial/defensive: pid wins over a mismatched program string).
    ///
    /// Fix round 4, item 1: with the plist ABSENT this is `.missing(staleLoadedJob: true)`, and it
    /// used to skip only the bootout, then run enable + bootstrap and re-judge a false-alarm
    /// `.stalePath` ("Crash protection is off"). launchd's in-memory job launched THIS process, so a
    /// crash relaunch works: write the plist quietly, no launchctl calls beyond the first `print`.
    @Test func neverBootsOutWhenTheLoadedPidIsThisProcessRegardlessOfTheProgramPath() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let uid: uid_t = 501
        let plistPath = dir.appendingPathComponent(LaunchAgentManager.plistName).path

        let runner = RecordingLaunchctlRunner(responses: [
            "print": [
                LaunchctlResult(status: 0, output: "program = /some/other/path\npid = 4242\n"),
                LaunchctlResult(status: 0, output: "program = /some/other/path\npid = 4242\n"),
            ]
        ])
        let state = await LaunchAgentManager.verifyAndRepair(
            executablePath: exe, launchAgentsDir: dir, uid: uid, currentPID: 4242, runner: runner
        )
        #expect(state == .healthy)
        let calls = await runner.calls
        #expect(calls == [["print", job(uid)]])
        let written = try String(contentsOfFile: plistPath, encoding: .utf8)
        #expect(LaunchAgentManager.programPath(inPlist: written) == exe)
    }

    /// Fix round 4, item 4: the quiet rewrite's plist write can fail (here: the LaunchAgents "dir"
    /// is a regular file, so `install` throws). Still `.healthy` with no launchctl calls beyond the
    /// first `print`: launchd's in-memory job is this process, so a crash relaunch still works.
    @Test func pidMatchQuietRewriteStaysHealthyWhenThePlistWriteFails() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let uid: uid_t = 501
        let notADir = dir.appendingPathComponent("LaunchAgents")
        try Data().write(to: notADir)

        let runner = RecordingLaunchctlRunner(responses: [
            "print": [LaunchctlResult(status: 0, output: "program = /some/other/path\npid = 4242\n")]
        ])
        let state = await LaunchAgentManager.verifyAndRepair(
            executablePath: exe, launchAgentsDir: notADir, uid: uid, currentPID: 4242, runner: runner
        )
        #expect(state == .healthy)
        let calls = await runner.calls
        #expect(calls == [["print", job(uid)]])
    }

    /// Fix round 2, item 1c (end to end): the on-disk plist already matches, but the loaded job
    /// (per `print`) points elsewhere — repaired as stalePath (bootout + rewrite + enable +
    /// bootstrap), never routed into a hand-over.
    @Test func plistMatchesButTheLoadedJobPointsElsewhereIsRepairedAsStalePath() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let uid: uid_t = 501
        let plistPath = dir.appendingPathComponent(LaunchAgentManager.plistName).path
        let staleProgram = "/Users/x/Downloads/Parley.app/Contents/MacOS/Parley"
        try await LaunchAgentManager.install(executablePath: exe, launchAgentsDir: dir, loadAgent: false)

        let runner = RecordingLaunchctlRunner(responses: [
            "print": [
                LaunchctlResult(status: 0, output: "program = \(staleProgram)\npid = 1\n"),
                LaunchctlResult(status: 0, output: "program = \(exe)\npid = 4242\n"),
            ]
        ])
        let state = await LaunchAgentManager.verifyAndRepair(
            executablePath: exe, launchAgentsDir: dir, uid: uid, currentPID: 4242, runner: runner
        )
        #expect(state == .healthy)
        let calls = await runner.calls
        #expect(calls == [
            ["print", job(uid)],
            ["bootout", job(uid)],
            ["enable", job(uid)],
            ["bootstrap", gui(uid), plistPath],
            ["print", job(uid)],
        ])
    }

    /// Fix round 3, item 2 (the realistic repair test round 2 asked for): the LIVE shape captured
    /// from `launchctl print` for a freshly-bootstrapped, not-yet-running job
    /// (`.superpowers/sdd/2026-09-24-capture-reliability/launchctl-print-live.txt`) has
    /// `state = not running` and NO `pid =` line at all. Starting from `.notLoaded`, the repair
    /// (enable + bootstrap) still correctly reports `.loadedButNotThisProcess` for that shape,
    /// rather than assuming an absent pid means it's this process.
    @Test func realisticPostBootstrapPrintWithNoPidLineIsLoadedButNotThisProcess() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let uid: uid_t = 501
        let plistPath = dir.appendingPathComponent(LaunchAgentManager.plistName).path
        try await LaunchAgentManager.install(executablePath: exe, launchAgentsDir: dir, loadAgent: false)

        // launchctl-print-live.txt's own shape: "state = not running", program present, no pid line.
        let liveShapeNoPid = """
        gui/501/eu.fmasi.parley = {
        \tactive count = 0
        \tpath = /Users/fmasi/Library/LaunchAgents/eu.fmasi.parley.plist
        \ttype = LaunchAgent
        \tstate = not running

        \tprogram = \(exe)
        \targuments = {
        \t\t\(exe)
        \t}

        \tdomain = gui/501 [100016]
        \tminimum runtime = 10
        \truns = 1
        \tlast exit code = 0
        }
        """
        let runner = RecordingLaunchctlRunner(responses: [
            "print": [LaunchctlResult(status: 1), LaunchctlResult(status: 0, output: liveShapeNoPid)]
        ])
        let state = await LaunchAgentManager.verifyAndRepair(
            executablePath: exe, launchAgentsDir: dir, uid: uid, currentPID: 4242, runner: runner
        )
        #expect(state == .loadedButNotThisProcess)
        let calls = await runner.calls
        #expect(calls == [
            ["print", job(uid)],
            ["enable", job(uid)],
            ["bootstrap", gui(uid), plistPath],
            ["print", job(uid)],
        ])
    }

    /// Fix round 3, item 3: a pid match is authoritative — launchd definitely spawned THIS process,
    /// so a mismatched program string (a stale/inconsistent on-disk plist, or a symlink/normalization
    /// quirk in `print`'s output) must not trigger a bootout/bootstrap dance. Just correct the file
    /// and report healthy, with no launchctl calls beyond the initial `print`.
    @Test func pidMatchWithADifferentProgramStringRewritesQuietlyAndIsHealthy() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let uid: uid_t = 501
        let plistPath = dir.appendingPathComponent(LaunchAgentManager.plistName).path
        let old = "/Users/x/Downloads/Parley.app/Contents/MacOS/Parley"
        try await LaunchAgentManager.install(executablePath: old, launchAgentsDir: dir, loadAgent: false)

        let runner = RecordingLaunchctlRunner(responses: [
            "print": [LaunchctlResult(status: 0, output: "program = \(old)\npid = 4242\n")]
        ])
        let state = await LaunchAgentManager.verifyAndRepair(
            executablePath: exe, launchAgentsDir: dir, uid: uid, currentPID: 4242, runner: runner
        )
        #expect(state == .healthy)
        let calls = await runner.calls
        #expect(calls == [["print", job(uid)]])
        let written = try String(contentsOfFile: plistPath, encoding: .utf8)
        #expect(LaunchAgentManager.programPath(inPlist: written) == exe)
    }

    // MARK: - install runs enable before bootstrap (item 1)

    @Test func installWithLoadAgentEnablesThenBootstraps() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let uid: uid_t = 501
        let plistPath = dir.appendingPathComponent(LaunchAgentManager.plistName).path
        let runner = RecordingLaunchctlRunner()

        try await LaunchAgentManager.install(executablePath: exe, launchAgentsDir: dir, loadAgent: true, uid: uid, runner: runner)

        let calls = await runner.calls
        #expect(calls == [["enable", job(uid)], ["bootstrap", gui(uid), plistPath]])
    }

    // MARK: - handOverToJob (item 4)

    /// Fix round 4, item 2: `-k`, so launchd RESTARTS a B that is still waiting for the lock and it
    /// gets a full fresh `lockWaitTimeout` window from A's kickstart. Without `-k`, kickstart on a
    /// running B returns 0 without restarting it; if B's deadline then passed before A exited, both
    /// would exit 0, leaving zero instances.
    @Test func handOverToJobRunsKickstartAndReportsSuccess() async {
        let uid: uid_t = 501
        let runner = RecordingLaunchctlRunner(responses: ["kickstart": [LaunchctlResult(status: 0)]])
        let ok = await LaunchAgentManager.handOverToJob(uid: uid, runner: runner)
        #expect(ok)
        let calls = await runner.calls
        #expect(calls == [["kickstart", "-k", job(uid)]])
    }

    @Test func handOverToJobReportsFailure() async {
        let runner = RecordingLaunchctlRunner(responses: ["kickstart": [LaunchctlResult(status: 1)]])
        let ok = await LaunchAgentManager.handOverToJob(uid: 501, runner: runner)
        #expect(!ok)
    }
}

/// Test double for `LaunchctlRunning`: records every invocation's exact argument array (fix round
/// 1, item 2) and returns a scripted result per verb (`args.first`), in call order; falls back to
/// `status: 0` once a verb's scripted responses are exhausted.
actor RecordingLaunchctlRunner: LaunchctlRunning {
    private(set) var calls: [[String]] = []
    private var responses: [String: [LaunchctlResult]]

    init(responses: [String: [LaunchctlResult]] = [:]) {
        self.responses = responses
    }

    func run(_ args: [String]) async -> LaunchctlResult {
        calls.append(args)
        guard let verb = args.first, var queue = responses[verb], !queue.isEmpty else {
            return LaunchctlResult(status: 0)
        }
        let next = queue.removeFirst()
        responses[verb] = queue
        return next
    }
}
