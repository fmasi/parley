import Testing
import Foundation
@testable import TranscriberCore

struct ConfigManagerTests {
    /// Creates a temporary directory for each test.
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigManagerTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Load defaults

    @Test func loadsDefaultsWhenNoFileExists() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let manager = ConfigManager(configDir: dir)
        #expect(manager.config == Config.default)
    }

    // MARK: - Save and reload

    @Test func saveAndReload() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let manager = ConfigManager(configDir: dir)
        manager.update { $0.outputFormat = "srt" }
        manager.update { $0.silenceTimeoutMinutes = 10 }

        // Create a new manager pointing at the same directory
        let reloaded = ConfigManager(configDir: dir)
        #expect(reloaded.config.outputFormat == "srt")
        #expect(reloaded.config.silenceTimeoutMinutes == 10)
    }

    // MARK: - Invalid JSON falls back to defaults

    @Test func invalidJSONFallsBackToDefaults() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let configFile = dir.appendingPathComponent("config.json")
        try "not valid json{{{".write(to: configFile, atomically: true, encoding: .utf8)

        let manager = ConfigManager(configDir: dir)
        #expect(manager.config == Config.default)
    }

    // MARK: - Creates directory on save

    @Test func createsDirectoryOnSave() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigManagerTests-\(UUID().uuidString)")
            .appendingPathComponent("nested")
        defer { cleanup(dir.deletingLastPathComponent()) }

        // Directory should not exist yet
        #expect(!FileManager.default.fileExists(atPath: dir.path))

        let manager = ConfigManager(configDir: dir)
        manager.save()

        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Update closure

    @Test func updateAppliesTransformAndPersists() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let manager = ConfigManager(configDir: dir)
        manager.update { config in
            config.hfToken = "hf_new_token"
            config.logLevel = "debug"
        }
        #expect(manager.config.hfToken == "hf_new_token")
        #expect(manager.config.logLevel == "debug")

        // Verify persisted
        let reloaded = ConfigManager(configDir: dir)
        #expect(reloaded.config.hfToken == "hf_new_token")
    }

    // MARK: - Partial JSON merges with defaults (unknown keys ignored)

    @Test func partialJSONDecodesAllFields() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // Write a complete JSON but with non-default values for only some fields
        let json = """
        {
            "recording_directory": "/custom",
            "silence_timeout_minutes": 5,
            "silence_detection_enabled": true,
            "output_format": "json",
            "launch_on_startup": true,
            "log_level": "info",
            "suppress_capture_warning": false,
            "hf_token": ""
        }
        """
        let configFile = dir.appendingPathComponent("config.json")
        try json.write(to: configFile, atomically: true, encoding: .utf8)

        let manager = ConfigManager(configDir: dir)
        #expect(manager.config.recordingDirectory == "/custom")
        #expect(manager.config.outputFormat == "json")
    }

    // MARK: - JSON with extra unknown keys falls back to defaults

    @Test func missingKeysInJSONFallsBackToDefaults() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // JSON missing required keys → decode fails → defaults
        let json = """
        {"recording_directory": "/only-this"}
        """
        let configFile = dir.appendingPathComponent("config.json")
        try json.write(to: configFile, atomically: true, encoding: .utf8)

        let manager = ConfigManager(configDir: dir)
        // Should fall back to defaults since decode fails
        #expect(manager.config == Config.default)
    }

    // MARK: - Multiple updates accumulate

    @Test func multipleUpdatesAccumulate() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let manager = ConfigManager(configDir: dir)
        manager.update { $0.outputFormat = "srt" }
        manager.update { $0.hfToken = "token123" }

        #expect(manager.config.outputFormat == "srt")
        #expect(manager.config.hfToken == "token123")
    }
}
