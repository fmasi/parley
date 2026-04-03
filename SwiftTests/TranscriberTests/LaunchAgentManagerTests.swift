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
        let plist = LaunchAgentManager.generatePlist(bundlePath: "/Applications/Transcriber.app")
        #expect(plist.contains("com.audio-transcribe.app"))
        #expect(plist.contains("/Applications/Transcriber.app"))
        #expect(plist.contains("KeepAlive"))
        #expect(plist.contains("<true/>"))
        #expect(plist.contains("ProcessType"))
        #expect(plist.contains("Interactive"))
    }

    // MARK: - install

    @Test func installWritesPlistFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        try LaunchAgentManager.install(
            bundlePath: "/Applications/Transcriber.app",
            launchAgentsDir: dir,
            loadAgent: false
        )

        let plistURL = dir.appendingPathComponent(LaunchAgentManager.plistName)
        #expect(FileManager.default.fileExists(atPath: plistURL.path))

        let content = try String(contentsOf: plistURL, encoding: .utf8)
        #expect(content.contains("com.audio-transcribe.app"))
        #expect(content.contains("/Applications/Transcriber.app"))
        #expect(content.contains("KeepAlive"))
    }

    // MARK: - uninstall

    @Test func uninstallRemovesPlistFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // First install
        try LaunchAgentManager.install(
            bundlePath: "/Applications/Transcriber.app",
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
            bundlePath: "/Applications/Transcriber.app",
            launchAgentsDir: dir,
            loadAgent: false
        )

        #expect(LaunchAgentManager.isInstalled(launchAgentsDir: dir))
    }
}
