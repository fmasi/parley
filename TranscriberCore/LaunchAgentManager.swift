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
                    // The verb (bootstrap/enable/bootout/print/kickstart) is `.public` so `log show`
                    // can be filtered/counted by it; the rest of the args (a plist path, gui/<uid>
                    // domain) stay `.private` (fix round 2, item 3). Non-zero exits log at `.error`
                    // so `log show` can diagnose a failed repair (fix round 1, item 5).
                    let verb = args.first ?? "?"
                    let rest = args.dropFirst().joined(separator: " ")
                    if status == 0 {
                        Logger.config.info("LaunchAgentManager: launchctl \(verb, privacy: .public) \(rest, privacy: .private) → \(status)")
                    } else {
                        Logger.config.error("LaunchAgentManager: launchctl \(verb, privacy: .public) \(rest, privacy: .private) → \(status, privacy: .public)")
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
                <string>\(xmlEscape(executablePath))</string>
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

    /// Escapes the five XML predefined entities (fix round 2, item 3): an unescaped `&`, `<`, `>`,
    /// `"` or `'` in the executable path would break the plist's XML. `&` is replaced FIRST so the
    /// entities this introduces aren't themselves re-escaped.
    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Reverses `xmlEscape`, in the opposite order (`&amp;` LAST, so a literal `&amp;` in the
    /// original path — already unlikely — isn't corrupted by an earlier substitution unescaping
    /// part of it). Needed so `programPath(inPlist:)` round-trips a `generatePlist`-written path
    /// exactly: without it, any path with an XML special character would compare unequal to the
    /// raw `executablePath` on every subsequent `verifyAndRepair` call and look permanently stale.
    private static func xmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Health

    /// `ProgramArguments[0]` of a plist string, or nil if absent. Regex on the generated shape:
    /// this manager writes the only plist it ever reads.
    public static func programPath(inPlist xml: String) -> String? {
        firstMatch(#"<key>ProgramArguments</key>\s*<array>\s*<string>([^<]+)</string>"#, in: xml).map(xmlUnescape)
    }

    /// `program = ` from `launchctl print gui/<uid>/<label>` output, or nil if absent (not loaded,
    /// or this launchd version's output doesn't include the line). (Fix round 1, item 3.)
    ///
    /// The capture is `(.+?)\s*$`, not `(\S+)` (fix round 2, item 1a): `\S+` truncated any install
    /// path containing a space at the first space — "/Applications/Parley 2.app/…/Parley" became
    /// "/Applications/Parley" — which then never matched `executablePath`, so `staleLoadedJob` came
    /// out true for a job that WAS this process, and `verifyAndRepair` booted it out.
    public static func loadedProgramPath(inPrintOutput output: String) -> String? {
        firstMatch(#"(?m)^\s*program\s*=\s*(.+?)\s*$"#, in: output)
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
        func query() async -> (state: LaunchAgentHealth.State, pid: pid_t?) {
            let job = await queryLoadedJob(uid: uid, runner: runner)
            let state = LaunchAgentHealth.assess(
                plistProgramPath: currentPlistPath(), executablePath: exePath, loaded: job.loaded,
                loadedProgramPath: job.programPath, loadedPID: job.pid, currentPID: currentPID
            )
            return (state, job.pid)
        }

        let before = await query()
        let state = before.state
        // NEVER bootout the job whose pid IS this process, no matter what the state says (fix
        // round 2, item 1b) — an absolute safety net independent of the classification above, in
        // case a program-path comparison is ever wrong (e.g. a symlink, an unusual launchd report).
        let isSelf = currentPID != nil && before.pid == currentPID
        let action = LaunchAgentHealth.action(for: state)
        // pid proves launchd's in-memory job launched exactly this process, so a crash relaunch
        // already works, whatever the on-disk plist or `print`'s program string says (fix round 3,
        // item 3; round 4, item 1; round 4b). Every plist-missing or plist-stale state therefore
        // takes the quiet rewrite: no bootout (it would SIGTERM this process), and no enable or
        // bootstrap (the job is already loaded; bootstrap would only fail with "already loaded").
        if isSelf, [.installAndBootstrap, .bootoutInstallAndBootstrap, .rewriteAndBootstrap].contains(action) {
            return await quietlyRewritePlist(from: state, executablePath: exePath, launchAgentsDir: agentsDir, plistURL: plistURL, runner: runner)
        }
        switch action {
        case .none:
            return state
        case .handOverToJob:
            // Not auto-repaired here (round 1, item 4): whether a hand-over is safe needs
            // recording/CLI-mode context this function doesn't have. A normal outcome (a Finder or
            // Sparkle launch while the job is loaded), not a failed repair: `.info`, the same as
            // the post-repair case below (fix round 4, item 5).
            Logger.config.info("LaunchAgentManager: health \(LaunchAgentHealth.logName(for: state), privacy: .public) — not auto-repaired here; hand-over pending")
            return state
        case .installAndBootstrap:
            try? await install(executablePath: exePath, launchAgentsDir: agentsDir, loadAgent: false, runner: runner)
            _ = await runner.run(["enable", "gui/\(uid)/\(label)"])
            _ = await runner.run(["bootstrap", "gui/\(uid)", plistURL.path])
        case .bootoutInstallAndBootstrap, .rewriteAndBootstrap:
            // A stale job must be booted out first or bootstrap fails with "already loaded". Never
            // this process's own job: `isSelf` returned above.
            _ = await runner.run(["bootout", "gui/\(uid)/\(label)"])
            try? await install(executablePath: exePath, launchAgentsDir: agentsDir, loadAgent: false, runner: runner)
            _ = await runner.run(["enable", "gui/\(uid)/\(label)"])
            _ = await runner.run(["bootstrap", "gui/\(uid)", plistURL.path])
        case .bootstrap:
            _ = await runner.run(["enable", "gui/\(uid)/\(label)"])
            _ = await runner.run(["bootstrap", "gui/\(uid)", plistURL.path])
        }
        let after = (await query()).state
        // Paths never appear `.public` (Global Constraints); state NAMES carry no user data.
        switch after {
        case .healthy:
            Logger.config.info("LaunchAgentManager: health \(LaunchAgentHealth.logName(for: state), privacy: .public) → \(LaunchAgentHealth.logName(for: after), privacy: .public)")
        case .loadedButNotThisProcess:
            // `bootstrap` always succeeds and starts the job as ITS OWN process: if THIS process
            // isn't that one (e.g. a Finder-launched duplicate that just repaired launchd's own
            // copy), that is a NORMAL outcome, not a failed repair — `.error` would be misleading.
            // The hand-over (`handOverToJob`) is what resolves it next, not another repair attempt
            // here. (Fix round 3, item 6.)
            Logger.config.info("LaunchAgentManager: health \(LaunchAgentHealth.logName(for: state), privacy: .public) → healthy but not launchd's process; hand-over pending")
        default:
            // Any OTHER non-healthy after-state means repair genuinely failed: `.error` so
            // `log show` surfaces it (fix round 1, item 5).
            Logger.config.error("LaunchAgentManager: health \(LaunchAgentHealth.logName(for: state), privacy: .public) → \(LaunchAgentHealth.logName(for: after), privacy: .public)")
        }
        if case .stalePath(let found) = state {
            Logger.config.info("LaunchAgentManager: plist pointed at \(found, privacy: .private)")
        }
        return after
    }

    /// The pid-confirmed repair (`isSelf` in `verifyAndRepair`): write the plist for
    /// `executablePath` and run NO launchctl verb — no bootout (it would SIGTERM this process), no
    /// enable/bootstrap (the job is already loaded and running as this process).
    private static func quietlyRewritePlist(
        from state: LaunchAgentHealth.State,
        executablePath: String,
        launchAgentsDir: URL,
        plistURL: URL,
        runner: LaunchctlRunning
    ) async -> LaunchAgentHealth.State {
        do {
            try await install(executablePath: executablePath, launchAgentsDir: launchAgentsDir, loadAgent: false, runner: runner)
            Logger.config.info("LaunchAgentManager: health \(LaunchAgentHealth.logName(for: state), privacy: .public) → healthy (pid confirmed self; plist rewritten, no launchctl calls)")
        } catch {
            // Still `.healthy`: launchd's in-memory job is this process, so a crash relaunch works.
            Logger.config.error("LaunchAgentManager: health \(LaunchAgentHealth.logName(for: state), privacy: .public) → healthy (pid confirmed self) but the plist rewrite at \(plistURL.path, privacy: .private) failed: \(error.localizedDescription, privacy: .private)")
        }
        return .healthy
    }

    /// `.loadedButNotThisProcess`: launchd's job is a DIFFERENT process than this one (Finder
    /// launch, a Sparkle relaunch, or quit-and-reopen), so this process's crash would not be
    /// relaunched. Runs `launchctl kickstart -k gui/<uid>/<label>` so launchd (re)starts its own
    /// copy of the job — call it B — and returns whether launchd accepted that.
    ///
    /// `-k` (fix round 4, item 2): without it, kickstart on a B that is already running (launchd
    /// starts the job at every `bootstrap`, so one may still be waiting for the lock from a
    /// launch-time repair) returns 0 WITHOUT restarting it. If that B's deadline then passed between
    /// A's kickstart and A's exit, both would exit 0 and nothing would relaunch either: zero
    /// instances. `-k` kills and restarts the job, so B always gets a full fresh
    /// `SingleInstancePolicy.lockWaitTimeout` window from A's kickstart. It is safe because A holds
    /// the single-instance lock: any running job process is a B waiting for it, never one recording.
    ///
    /// The full hand-over protocol (fix round 2, item 2 — a design correction: round 1's plan was
    /// "kickstart then yield", which as DOCUMENTED left NO instance running. This process, A, still
    /// holds the single-instance flock when launchd starts B; B's duplicate-instance check would
    /// see the lock held and exit 0 immediately — `SuccessfulExit: false` means launchd does not
    /// relaunch a clean exit — and then A would exit too, having handed off to nothing):
    /// 1. This process, A, calls `handOverToJob`.
    /// 2. On success, A releases the single-instance lock and exits 0 straight away, well inside
    ///    B's fresh window. On failure, A keeps running (better a process KeepAlive can't protect
    ///    than none at all); the state still maps to `LaunchAgentHealth.userMessage` for "crash
    ///    protection is off".
    /// 3. B, launchd-spawned, recognises it IS the launchd job (`SingleInstancePolicy.decide(isLaunchdJob:
    ///    true, lockHeldByOther: true)` → `.waitForLock`) and WAITS up to
    ///    `SingleInstancePolicy.lockWaitTimeout` for A to release the lock, instead of yielding —
    ///    every OTHER duplicate launch still yields immediately (`.yield`).
    /// 4. If that wait times out (A never released the lock),
    ///    `SingleInstancePolicy.TimeoutOutcome.exitZero` is B's ONLY allowed outcome: B exits 0.
    ///    launchd starts this job at EVERY `bootstrap`, so this is not rare: the B started by a
    ///    launch-time repair times out whenever A does not hand over (A is recording, inside
    ///    `handOverCooldown`, or its kickstart failed). B must neither exit non-zero (KeepAlive
    ///    would respawn it roughly every 10 s, a relaunch loop) nor proceed unlocked (two
    ///    instances); A, still running, remains the one surviving instance. (Fix round 3, item 1.)
    ///    When A DOES hand over, `-k` restarted B at the kickstart, so B's full window outlasts A's
    ///    prompt exit (step 2) and B takes the lock. (Fix round 4, item 2.)
    ///
    /// `LaunchAgentHealth.shouldAttemptHandOver`'s `lastHandOverAt` guard must be persisted ACROSS
    /// PROCESSES (e.g. `UserDefaults`, by L3): A does not survive a successful hand-over to
    /// remember it in memory, so an in-memory `lastHandOverAt` would reset to nil on every attempt
    /// and the cooldown would never actually apply.
    ///
    /// Callers MUST gate this call with `LaunchAgentHealth.shouldAttemptHandOver` first (never while
    /// recording, never in CLI mode, never from the launchd job itself (`isLaunchdJob`), never twice
    /// within `handOverCooldown`) — this method performs no such guard itself, since it has no idea
    /// whether a recording is in progress or which process it is running in. The exit/yield
    /// wiring (steps 2–3) and `SingleInstancePolicy`'s call site (detecting `isLaunchdJob`, e.g. via
    /// the `XPC_SERVICE_NAME` environment variable equalling `label`) belong to task L3; this
    /// Manager provides only the kickstart call and `SingleInstancePolicy`'s pure decision table —
    /// no app files are touched here.
    public static func handOverToJob(uid: uid_t = getuid(), runner: LaunchctlRunning = ProcessLaunchctlRunner()) async -> Bool {
        let result = await runner.run(["kickstart", "-k", "gui/\(uid)/\(label)"])
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
