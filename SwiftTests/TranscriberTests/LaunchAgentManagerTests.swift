import Testing
import Foundation
@testable import TranscriberCore

struct LaunchAgentManagerTests {
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
        let plist = LaunchAgentManager.generatePlist(executablePath: "/Applications/Transcriber.app/Contents/MacOS/AudioTranscribe")
        #expect(plist.contains("com.audio-transcribe.app"))
        #expect(plist.contains("ProgramArguments"))
        #expect(plist.contains("/Applications/Transcriber.app/Contents/MacOS/AudioTranscribe"))
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
        let plist = LaunchAgentManager.generatePlist(executablePath: "/Applications/Transcriber.app/Contents/MacOS/AudioTranscribe")
        #expect(plist.contains("<key>SuccessfulExit</key>"))
        #expect(plist.contains("<false/>"))
        // Sanity: the boolean form must not slip back in.
        let keepAliveBoolean = "<key>KeepAlive</key>\n            <true/>"
        #expect(!plist.contains(keepAliveBoolean))
    }

    // MARK: - install

    @Test func installWritesPlistFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        try LaunchAgentManager.install(
            executablePath: "/Applications/Transcriber.app/Contents/MacOS/AudioTranscribe",
            launchAgentsDir: dir,
            loadAgent: false
        )

        let plistURL = dir.appendingPathComponent(LaunchAgentManager.plistName)
        #expect(FileManager.default.fileExists(atPath: plistURL.path))

        let content = try String(contentsOf: plistURL, encoding: .utf8)
        #expect(content.contains("com.audio-transcribe.app"))
        #expect(content.contains("ProgramArguments"))
        #expect(content.contains("/Applications/Transcriber.app/Contents/MacOS/AudioTranscribe"))
        #expect(content.contains("KeepAlive"))
    }

    // MARK: - uninstall

    @Test func uninstallRemovesPlistFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // First install
        try LaunchAgentManager.install(
            executablePath: "/Applications/Transcriber.app/Contents/MacOS/AudioTranscribe",
            launchAgentsDir: dir,
            loadAgent: false
        )

        let plistURL = dir.appendingPathComponent(LaunchAgentManager.plistName)
        #expect(FileManager.default.fileExists(atPath: plistURL.path))

        // Now uninstall
        LaunchAgentManager.uninstall(launchAgentsDir: dir, unloadAgent: false)

        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
    }

    // MARK: - isInstalled

    @Test func isInstalledReturnsFalseWhenMissing() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        #expect(!LaunchAgentManager.isInstalled(launchAgentsDir: dir))
    }

    @Test func isInstalledReturnsTrueAfterInstall() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        try LaunchAgentManager.install(
            executablePath: "/Applications/Transcriber.app/Contents/MacOS/AudioTranscribe",
            launchAgentsDir: dir,
            loadAgent: false
        )

        #expect(LaunchAgentManager.isInstalled(launchAgentsDir: dir))
    }
}
