import Foundation
import os

/// Manages a macOS LaunchAgent plist that instructs `launchd` to restart the app after crashes.
///
/// Typical usage:
/// - Call `install()` at app startup to register the LaunchAgent.
/// - Call `uninstall()` before a clean quit (Cmd+Q) so macOS does not restart the app.
public enum LaunchAgentManager {
    public static let label = "com.audio-transcribe.app"
    public static let plistName = "\(label).plist"

    // MARK: - Plist generation

    /// Returns an XML plist string for a LaunchAgent that relaunches the app on abnormal exit.
    ///
    /// `KeepAlive` is intentionally a dict with `SuccessfulExit: false` (NOT a plain `<true/>`).
    /// With the boolean form, `launchctl load -w` will spawn the app immediately even when an
    /// instance is already running via LaunchServices (e.g. dev.py's `open AudioTranscribe.app`),
    /// producing two menu-bar icons. The dict form scopes relaunch to crash recovery only, which
    /// matches the actual purpose of this LaunchAgent.
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
    /// - Parameters:
    ///   - executablePath: Path to the app executable. Defaults to `Bundle.main.executablePath`.
    ///   - launchAgentsDir: Directory to write the plist into. Defaults to `~/Library/LaunchAgents`.
    ///   - loadAgent: When `true`, calls `launchctl load` after writing the plist. Pass `false` in tests.
    public static func install(
        executablePath: String? = nil,
        launchAgentsDir: URL? = nil,
        loadAgent: Bool = true
    ) throws {
        let exePath = executablePath ?? Bundle.main.executablePath ?? Bundle.main.bundlePath
        let agentsDir = launchAgentsDir ?? defaultLaunchAgentsDir()

        // Ensure the LaunchAgents directory exists.
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        let plistURL = agentsDir.appendingPathComponent(plistName)
        let content = generatePlist(executablePath: exePath)
        try content.write(to: plistURL, atomically: true, encoding: .utf8)
        Logger.config.info("LaunchAgentManager: wrote plist to \(plistURL.path)")

        if loadAgent {
            runLaunchctl(args: ["load", "-w", plistURL.path])
        }
    }

    // MARK: - Uninstall

    /// Unloads the LaunchAgent and removes the plist file.
    ///
    /// - Parameters:
    ///   - launchAgentsDir: Directory containing the plist. Defaults to `~/Library/LaunchAgents`.
    ///   - unloadAgent: When `true`, calls `launchctl unload` before removing the plist. Pass `false` in tests.
    public static func uninstall(
        launchAgentsDir: URL? = nil,
        unloadAgent: Bool = true
    ) {
        let agentsDir = launchAgentsDir ?? defaultLaunchAgentsDir()
        let plistURL = agentsDir.appendingPathComponent(plistName)

        if unloadAgent && FileManager.default.fileExists(atPath: plistURL.path) {
            runLaunchctl(args: ["unload", "-w", plistURL.path])
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

    @discardableResult
    private static func runLaunchctl(args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            let status = process.terminationStatus
            Logger.config.info("LaunchAgentManager: launchctl \(args.joined(separator: " ")) → \(status)")
            return status
        } catch {
            Logger.config.error("LaunchAgentManager: launchctl failed: \(error.localizedDescription)")
            return -1
        }
    }
}
