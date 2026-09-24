import Foundation
import os

// MARK: - launchctl seam (injectable for tests; fix round 1, item 2)

/// One `launchctl` invocation's result: exit status and captured stdout. The output is needed to
/// parse `print`'s `program =`/`pid =` lines (`LaunchAgentManager.loadedProgramPath`/`loadedPID`)
/// without a second round-trip.
public struct LaunchctlResult: Sendable, Equatable {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }
}

/// Runs `launchctl` with the given arguments. Production goes through `Process`
/// (`ProcessLaunchctlRunner`); tests inject a recording double that never touches the real
/// launchd, so the exact argument sequence per repair action can be asserted.
public protocol LaunchctlRunning: Sendable {
    func run(_ args: [String]) async -> LaunchctlResult
}

/// The real `launchctl` binary, off the main thread (#197): `Process.waitUntilExit()` is a
/// blocking, synchronous wait, and this used to run straight on main at both launch and Quit.
public struct ProcessLaunchctlRunner: LaunchctlRunning {
    public init() {}

    public func run(_ args: [String]) async -> LaunchctlResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                do {
                    try process.run()
                    // Read while the process runs (not after waitUntilExit): a full pipe buffer
                    // would otherwise deadlock the child against this read.
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let status = process.terminationStatus
                    let output = String(data: data, encoding: .utf8) ?? ""
                    // Non-zero exits at `.error` so `log show` can diagnose a failed repair (fix
                    // round 1, item 5); this line carries no path, only verbs/ids.
                    if status == 0 {
                        Logger.config.info("LaunchAgentManager: launchctl \(args.joined(separator: " ")) → \(status)")
                    } else {
                        Logger.config.error("LaunchAgentManager: launchctl \(args.joined(separator: " ")) → \(status, privacy: .public)")
                    }
                    continuation.resume(returning: LaunchctlResult(status: status, output: output))
                } catch {
                    Logger.config.error("LaunchAgentManager: launchctl failed: \(error.localizedDescription)")
                    continuation.resume(returning: LaunchctlResult(status: -1))
                }
            }
        }
    }
}

/// Manages a macOS LaunchAgent plist that instructs `launchd` to restart the app after crashes.
///
/// Typical usage:
/// - Call `install()` at app startup to register the LaunchAgent.
/// - Call `uninstall()` before a clean quit (Cmd+Q) so macOS does not restart the app.
public enum LaunchAgentManager {
    public static let label = "eu.fmasi.parley"
    public static let plistName = "\(label).plist"

    // MARK: - Plist generation

    /// Returns an XML plist string for a LaunchAgent that relaunches the app on abnormal exit.
    ///
    /// `KeepAlive` is a dict with `SuccessfulExit: false` (NOT a plain `<true/>`) to scope relaunch
    /// to *abnormal* exits — i.e. only after a crash, which is this agent's whole purpose. A clean
    /// quit or a single-instance-guard `exit(0)` therefore does NOT trigger a relaunch.
    ///
    /// NOTE (#109): the dict form does NOT prevent the launch-on-load duplicate. launchd starts a
    /// KeepAlive job at load time regardless of dict-vs-boolean, so `install(loadAgent: true)` from
    /// inside the running app spawns a second instance. That is handled by the single-instance guard
    /// in `TranscriberApp` (`SingleInstanceGuard`), which makes the duplicate exit cleanly — see
    /// gotcha #54. The dict form is still correct for its own reason (crash-only relaunch).
    public static func generatePlist(executablePath: String) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
            </array>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
    }

    // MARK: - Health

    /// `ProgramArguments[0]` of a plist string, or nil if absent. Regex on the generated shape:
    /// this manager writes the only plist it ever reads.
    public static func programPath(inPlist xml: String) -> String? {
        firstMatch(#"<key>ProgramArguments</key>\s*<array>\s*<string>([^<]+)</string>"#, in: xml)
    }

    /// `program = ` from `launchctl print gui/<uid>/<label>` output, or nil if absent (not loaded,
    /// or this launchd version's output doesn't include the line). (Fix round 1, item 3.)
    public static func loadedProgramPath(inPrintOutput output: String) -> String? {
        firstMatch(#"(?m)^\s*program\s*=\s*(\S+)"#, in: output)
    }

    /// `pid = ` from `launchctl print` output, or nil if absent (loaded but not currently running,
    /// or no pid line in this launchd version's output). (Fix round 1, item 4.)
    public static func loadedPID(inPrintOutput output: String) -> pid_t? {
        firstMatch(#"(?m)^\s*pid\s*=\s*(\d+)"#, in: output).flatMap { pid_t($0) }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// One `print` call's worth of facts: whether the job is loaded, and (if so) the program path
    /// and pid launchd reports for it.
    private static func queryLoadedJob(uid: uid_t, runner: LaunchctlRunning) async -> (loaded: Bool, programPath: String?, pid: pid_t?) {
        let result = await runner.run(["print", "gui/\(uid)/\(label)"])
        guard result.status == 0 else { return (false, nil, nil) }
        return (true, loadedProgramPath(inPrintOutput: result.output), loadedPID(inPrintOutput: result.output))
    }

    /// Whether launchd currently has the job (`launchctl print gui/<uid>/<label>` exits 0).
    public static func isLoaded(uid: uid_t = getuid(), runner: LaunchctlRunning = ProcessLaunchctlRunner()) async -> Bool {
        await queryLoadedJob(uid: uid, runner: runner).loaded
    }

    /// Judge, repair, and re-judge. Returns the state AFTER repair, so the caller shows the
    /// "crash protection is off" row only when repair failed.
    ///
    /// `.loadedButNotThisProcess` is judged (via `currentPID`, default `getpid()`) but never
    /// auto-repaired here: whether a hand-over is safe depends on recording/CLI-mode state this
    /// function has no access to. Call `LaunchAgentManager.handOverToJob` directly, gated by
    /// `LaunchAgentHealth.shouldAttemptHandOver`, when that context is available (L3).
    public static func verifyAndRepair(
        executablePath: String? = nil,
        launchAgentsDir: URL? = nil,
        uid: uid_t = getuid(),
        currentPID: pid_t? = getpid(),
        runner: LaunchctlRunning = ProcessLaunchctlRunner()
    ) async -> LaunchAgentHealth.State {
        let exePath = executablePath ?? Bundle.main.executablePath ?? Bundle.main.bundlePath
        let agentsDir = launchAgentsDir ?? defaultLaunchAgentsDir()
        let plistURL = agentsDir.appendingPathComponent(plistName)
        func currentPlistPath() -> String? {
            (try? String(contentsOf: plistURL, encoding: .utf8)).flatMap(programPath(inPlist:))
        }
        func assessNow() async -> LaunchAgentHealth.State {
            let job = await queryLoadedJob(uid: uid, runner: runner)
            return LaunchAgentHealth.assess(
                plistProgramPath: currentPlistPath(), executablePath: exePath, loaded: job.loaded,
                loadedProgramPath: job.programPath, loadedPID: job.pid, currentPID: currentPID
            )
        }

        let state = await assessNow()
        switch LaunchAgentHealth.action(for: state) {
        case .none, .handOverToJob:
            return state
        case .installAndBootstrap:
            try? await install(executablePath: exePath, launchAgentsDir: agentsDir, loadAgent: false, runner: runner)
            _ = await runner.run(["enable", "gui/\(uid)/\(label)"])
            _ = await runner.run(["bootstrap", "gui/\(uid)", plistURL.path])
        case .bootoutInstallAndBootstrap, .rewriteAndBootstrap:
            // A stale job must be booted out first or bootstrap fails with "already loaded".
            _ = await runner.run(["bootout", "gui/\(uid)/\(label)"])
            try? await install(executablePath: exePath, launchAgentsDir: agentsDir, loadAgent: false, runner: runner)
            _ = await runner.run(["enable", "gui/\(uid)/\(label)"])
            _ = await runner.run(["bootstrap", "gui/\(uid)", plistURL.path])
        case .bootstrap:
            _ = await runner.run(["enable", "gui/\(uid)/\(label)"])
            _ = await runner.run(["bootstrap", "gui/\(uid)", plistURL.path])
        }
        let after = await assessNow()
        // Paths never appear `.public` (Global Constraints); state NAMES carry no user data.
        if after == .healthy {
            Logger.config.info("LaunchAgentManager: health \(LaunchAgentHealth.logName(for: state), privacy: .public) → \(LaunchAgentHealth.logName(for: after), privacy: .public)")
        } else {
            // A non-healthy after-state means repair failed: `.error` so `log show` surfaces it
            // (fix round 1, item 5).
            Logger.config.error("LaunchAgentManager: health \(LaunchAgentHealth.logName(for: state), privacy: .public) → \(LaunchAgentHealth.logName(for: after), privacy: .public)")
        }
        if case .stalePath(let found) = state {
            Logger.config.info("LaunchAgentManager: plist pointed at \(found, privacy: .private)")
        }
        return after
    }

    /// `.loadedButNotThisProcess`: launchd's job is a DIFFERENT process than this one (Finder
    /// launch, a Sparkle relaunch, or quit-and-reopen), so this process's crash would not be
    /// relaunched. Runs `launchctl kickstart gui/<uid>/<label>` so launchd (re)starts its own copy
    /// of the job, and returns whether launchd accepted that. On success, the launchd-spawned copy
    /// is now starting; the caller (L3) must then make THIS process yield (`exit(0)`) so only one
    /// copy survives — that exit/yield wiring is out of this Manager's scope. On failure, this
    /// process must stay running (better a process KeepAlive can't protect than none at all); the
    /// state still maps to `LaunchAgentHealth.userMessage` for "crash protection is off".
    ///
    /// Callers MUST gate this with `LaunchAgentHealth.shouldAttemptHandOver` first (never while
    /// recording, never in CLI mode, never twice within `handOverCooldown`) — this method performs
    /// no such guard itself, since it has no idea whether a recording is in progress.
    public static func handOverToJob(uid: uid_t = getuid(), runner: LaunchctlRunning = ProcessLaunchctlRunner()) async -> Bool {
        let result = await runner.run(["kickstart", "gui/\(uid)/\(label)"])
        return result.status == 0
    }

    // MARK: - Install

    /// Installs the LaunchAgent plist and optionally loads it with `launchctl`.
    ///
    /// Async (#197): `launchctl load` is a subprocess wait (`Process.waitUntilExit`), and this is
    /// called from app launch. The wait itself runs off the main thread; this suspends without
    /// blocking it.
    ///
    /// `enable` runs immediately before `bootstrap` (fix round 1, item 1 — CRITICAL): a probe job
    /// proved that after `uninstall`'s old `unload -w` set launchd's per-job disabled override,
    /// `bootstrap` alone failed with "5: Input/output error" (`print` then reported 113), while
    /// `enable` immediately before `bootstrap` succeeded. `enable` is idempotent when the job was
    /// never disabled, so it is unconditional here rather than judged.
    ///
    /// - Parameters:
    ///   - executablePath: Path to the app executable. Defaults to `Bundle.main.executablePath`.
    ///   - launchAgentsDir: Directory to write the plist into. Defaults to `~/Library/LaunchAgents`.
    ///   - loadAgent: When `true`, calls `launchctl enable` + `bootstrap` after writing the plist.
    ///     Pass `false` in tests.
    ///   - uid: The `gui/<uid>` domain to bootstrap into. Defaults to the real user id.
    ///   - runner: The `launchctl` seam. Defaults to the real binary; tests inject a recorder.
    public static func install(
        executablePath: String? = nil,
        launchAgentsDir: URL? = nil,
        loadAgent: Bool = true,
        uid: uid_t = getuid(),
        runner: LaunchctlRunning = ProcessLaunchctlRunner()
    ) async throws {
        let exePath = executablePath ?? Bundle.main.executablePath ?? Bundle.main.bundlePath
        let agentsDir = launchAgentsDir ?? defaultLaunchAgentsDir()

        // Ensure the LaunchAgents directory exists.
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        let plistURL = agentsDir.appendingPathComponent(plistName)
        let content = generatePlist(executablePath: exePath)
        try content.write(to: plistURL, atomically: true, encoding: .utf8)
        Logger.config.info("LaunchAgentManager: wrote plist to \(plistURL.path)")

        if loadAgent {
            _ = await runner.run(["enable", "gui/\(uid)/\(label)"])
            _ = await runner.run(["bootstrap", "gui/\(uid)", plistURL.path])
        }
    }

    // MARK: - Uninstall

    /// Removes the plist file and unloads the LaunchAgent.
    ///
    /// Order matters (gotcha #75): on a launchd-spawned instance (post-crash relaunch),
    /// `launchctl unload`/`bootout` SIGTERMs this very process — the default action terminates it
    /// immediately, wherever execution currently is, so nothing after that point in the caller
    /// runs. The plist removal used to come after the unload/bootout call and so never ran on that
    /// path, leaving the file behind. Removing the file FIRST means it is gone even if the bootout
    /// call ends the process before returning.
    ///
    /// Async (#197): see `install` above — the same subprocess-wait concern applies here, called
    /// on Quit.
    ///
    /// - Parameters:
    ///   - launchAgentsDir: Directory containing the plist. Defaults to `~/Library/LaunchAgents`.
    ///   - unloadAgent: When `true`, calls `launchctl bootout` after removing the plist. Pass `false` in tests.
    ///   - uid: The `gui/<uid>` domain to boot out of. Defaults to the real user id.
    ///   - runner: The `launchctl` seam. Defaults to the real binary; tests inject a recorder.
    public static func uninstall(
        launchAgentsDir: URL? = nil,
        unloadAgent: Bool = true,
        uid: uid_t = getuid(),
        runner: LaunchctlRunning = ProcessLaunchctlRunner()
    ) async {
        let agentsDir = launchAgentsDir ?? defaultLaunchAgentsDir()
        let plistURL = agentsDir.appendingPathComponent(plistName)
        let existed = FileManager.default.fileExists(atPath: plistURL.path)

        do {
            try FileManager.default.removeItem(at: plistURL)
            Logger.config.info("LaunchAgentManager: removed plist at \(plistURL.path)")
        } catch {
            Logger.config.warning("LaunchAgentManager: could not remove plist: \(error.localizedDescription)")
        }

        if unloadAgent && existed {
            _ = await runner.run(["bootout", "gui/\(uid)/\(label)"])
        }
    }

    // MARK: - Status check

    /// Returns `true` if the plist file exists in the LaunchAgents directory.
    public static func isInstalled(launchAgentsDir: URL? = nil) -> Bool {
        let agentsDir = launchAgentsDir ?? defaultLaunchAgentsDir()
        let plistURL = agentsDir.appendingPathComponent(plistName)
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    // MARK: - Private helpers

    private static func defaultLaunchAgentsDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
    }
}
