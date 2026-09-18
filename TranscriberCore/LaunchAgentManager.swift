import Foundation
import os

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

    // MARK: - Install

    /// Installs the LaunchAgent plist and optionally loads it with `launchctl`.
    ///
    /// Async (#197): `launchctl load` is a subprocess wait (`Process.waitUntilExit`), and this is
    /// called from app launch. The wait itself runs off the main thread; this suspends without
    /// blocking it.
    ///
    /// - Parameters:
    ///   - executablePath: Path to the app executable. Defaults to `Bundle.main.executablePath`.
    ///   - launchAgentsDir: Directory to write the plist into. Defaults to `~/Library/LaunchAgents`.
    ///   - loadAgent: When `true`, calls `launchctl load` after writing the plist. Pass `false` in tests.
    public static func install(
        executablePath: String? = nil,
        launchAgentsDir: URL? = nil,
        loadAgent: Bool = true
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
            _ = await runLaunchctl(args: ["load", "-w", plistURL.path])
        }
    }

    // MARK: - Uninstall

    /// Unloads the LaunchAgent and removes the plist file.
    ///
    /// Async (#197): see `install` above — the same subprocess-wait concern applies here, called
    /// on Quit. CAUTION: on a launchd-spawned instance (post-crash relaunch), `launchctl unload`
    /// sends this very process SIGTERM — the default action terminates it immediately, wherever
    /// execution currently is, so nothing after that point in the caller (including the removal
    /// below, or a subsequent `NSApplication.terminate(nil)`) runs. That was already true when the
    /// wait was synchronous on main, and stays true here: the signal is process-wide, not
    /// thread-specific, so moving the wait off main does not change which lines execute.
    ///
    /// - Parameters:
    ///   - launchAgentsDir: Directory containing the plist. Defaults to `~/Library/LaunchAgents`.
    ///   - unloadAgent: When `true`, calls `launchctl unload` before removing the plist. Pass `false` in tests.
    public static func uninstall(
        launchAgentsDir: URL? = nil,
        unloadAgent: Bool = true
    ) async {
        let agentsDir = launchAgentsDir ?? defaultLaunchAgentsDir()
        let plistURL = agentsDir.appendingPathComponent(plistName)

        if unloadAgent && FileManager.default.fileExists(atPath: plistURL.path) {
            _ = await runLaunchctl(args: ["unload", "-w", plistURL.path])
        }

        do {
            try FileManager.default.removeItem(at: plistURL)
            Logger.config.info("LaunchAgentManager: removed plist at \(plistURL.path)")
        } catch {
            Logger.config.warning("LaunchAgentManager: could not remove plist: \(error.localizedDescription)")
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

    /// Runs `launchctl` and awaits it, off the main thread (#197): `Process.waitUntilExit()` is a
    /// blocking, synchronous wait, and this used to run straight on main at both launch and Quit.
    @discardableResult
    private static func runLaunchctl(args: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = args
                do {
                    try process.run()
                    process.waitUntilExit()   // off main: the caller is suspended, not blocked
                    let status = process.terminationStatus
                    Logger.config.info("LaunchAgentManager: launchctl \(args.joined(separator: " ")) → \(status)")
                    continuation.resume(returning: status)
                } catch {
                    Logger.config.error("LaunchAgentManager: launchctl failed: \(error.localizedDescription)")
                    continuation.resume(returning: -1)
                }
            }
        }
    }
}
