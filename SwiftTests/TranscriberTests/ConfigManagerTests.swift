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
            config.engine = .fluidAudio
        }
        #expect(manager.config.engine == .fluidAudio)

        // Verify persisted
        let reloaded = ConfigManager(configDir: dir)
        #expect(reloaded.config.engine == .fluidAudio)
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
            "suppress_capture_warning": false
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
        manager.update { $0.engine = .fluidAudio }

        #expect(manager.config.outputFormat == "srt")
        #expect(manager.config.engine == .fluidAudio)
    }

    // MARK: - #48 summary API key Keychain migration

    /// A config.json written by a pre-#48 build, with a real plaintext key still in it. Built via
    /// `JSONSerialization` rather than string interpolation into a JSON literal, so a key
    /// containing `"`, `\`, or any other JSON metacharacter still produces valid JSON instead of
    /// corrupting the fixture.
    private func legacyConfigJSON(apiKey: String) throws -> String {
        let dict: [String: Any] = [
            "recording_directory": "/tmp", "silence_timeout_minutes": 5,
            "silence_detection_enabled": true, "output_format": "txt",
            "launch_on_startup": true, "suppress_capture_warning": false,
            "summary": [
                "enabled": true, "provider": "openai",
                "endpoint": "https://api.openai.com/v1",
                "api_key": apiKey, "model": "gpt-4o-mini",
            ],
        ]
        return String(data: try JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!
    }

    @Test func migratesLegacyPlaintextAPIKeyToKeychainAndClearsIt() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let configFile = dir.appendingPathComponent("config.json")
        try legacyConfigJSON(apiKey: "sk-legacy-plaintext").write(to: configFile, atomically: true, encoding: .utf8)

        let keychain = FakeKeychainStore()
        _ = ConfigManager(configDir: dir, keychainStore: keychain)

        // The key made it into the Keychain...
        #expect(SummaryAPIKeyStore.load(keychain: keychain) == "sk-legacy-plaintext")

        // ...and config.json no longer has it, anywhere.
        let rewritten = try String(contentsOf: configFile, encoding: .utf8)
        #expect(!rewritten.contains("sk-legacy-plaintext"))
        #expect(!rewritten.contains("api_key"))

        // The rest of the summary config survived the rewrite untouched.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: configFile)) as? [String: Any]
        let summaryJSON = json?["summary"] as? [String: Any]
        #expect(summaryJSON?["endpoint"] as? String == "https://api.openai.com/v1")
        #expect(summaryJSON?["model"] as? String == "gpt-4o-mini")
    }

    @Test func migrationIsIdempotentAcrossRepeatedLaunches() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let configFile = dir.appendingPathComponent("config.json")
        try legacyConfigJSON(apiKey: "sk-legacy-plaintext").write(to: configFile, atomically: true, encoding: .utf8)

        let keychain = FakeKeychainStore()
        _ = ConfigManager(configDir: dir, keychainStore: keychain)
        #expect(keychain.setCallCount == 1)

        // A second "launch" against the now-migrated file must be a safe no-op: nothing left to
        // migrate, so no further Keychain write, and the key already there is undisturbed.
        _ = ConfigManager(configDir: dir, keychainStore: keychain)
        #expect(keychain.setCallCount == 1)
        #expect(SummaryAPIKeyStore.load(keychain: keychain) == "sk-legacy-plaintext")
    }

    @Test func configWithNoAPIKeyIsUnaffectedByMigration() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let configFile = dir.appendingPathComponent("config.json")
        // No `summary` block at all — the common case (summaries never configured).
        let json = """
        {"recording_directory":"/tmp","silence_timeout_minutes":5,"silence_detection_enabled":true,\
        "output_format":"txt","launch_on_startup":true,"suppress_capture_warning":false}
        """
        try json.write(to: configFile, atomically: true, encoding: .utf8)
        let originalContents = try String(contentsOf: configFile, encoding: .utf8)

        let keychain = FakeKeychainStore()
        let manager = ConfigManager(configDir: dir, keychainStore: keychain)

        #expect(keychain.setCallCount == 0)
        #expect(SummaryAPIKeyStore.load(keychain: keychain) == "")
        #expect(manager.config.summary == nil)
        // File on disk wasn't touched (no migration write happened).
        #expect(try String(contentsOf: configFile, encoding: .utf8) == originalContents)
    }

    @Test func configWithEmptyAPIKeyIsUnaffectedByMigration() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let configFile = dir.appendingPathComponent("config.json")
        try legacyConfigJSON(apiKey: "").write(to: configFile, atomically: true, encoding: .utf8)

        let keychain = FakeKeychainStore()
        _ = ConfigManager(configDir: dir, keychainStore: keychain)

        // An empty api_key (the local-LM-Studio-with-no-key case from the issue) is not a secret
        // to migrate — nothing should be written to the Keychain for it.
        #expect(keychain.setCallCount == 0)
        #expect(SummaryAPIKeyStore.load(keychain: keychain) == "")
    }

    @Test func alreadyMigratedConfigRoundTripsCleanly() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let configFile = dir.appendingPathComponent("config.json")
        // No `api_key` field — as config.json looks after migration (or on a config that was
        // always written by a post-#48 build via Settings).
        let json = """
        {"recording_directory":"/tmp","silence_timeout_minutes":5,"silence_detection_enabled":true,\
        "output_format":"txt","launch_on_startup":true,"suppress_capture_warning":false,\
        "summary":{"enabled":true,"provider":"openai","endpoint":"https://api.openai.com/v1",\
        "model":"gpt-4o-mini"}}
        """
        try json.write(to: configFile, atomically: true, encoding: .utf8)

        let keychain = FakeKeychainStore()
        let manager = ConfigManager(configDir: dir, keychainStore: keychain)

        #expect(keychain.setCallCount == 0)
        #expect(manager.config.summary?.enabled == true)
        #expect(manager.config.summary?.endpoint == "https://api.openai.com/v1")
        #expect(manager.config.summary?.model == "gpt-4o-mini")

        // A subsequent save() (e.g. from an unrelated Settings change) doesn't reintroduce the key.
        manager.update { $0.silenceTimeoutMinutes = 7 }
        let rewritten = try String(contentsOf: configFile, encoding: .utf8)
        #expect(!rewritten.contains("api_key"))
    }

    @Test func migrationLeavesConfigJSONUntouchedWhenKeychainWriteFails() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let configFile = dir.appendingPathComponent("config.json")
        try legacyConfigJSON(apiKey: "sk-legacy-plaintext").write(to: configFile, atomically: true, encoding: .utf8)
        let originalContents = try String(contentsOf: configFile, encoding: .utf8)

        let keychain = FakeKeychainStore()
        keychain.setError = KeychainError.unexpectedStatus(-1)
        _ = ConfigManager(configDir: dir, keychainStore: keychain)

        // The key must never be dropped from config.json before it's confirmed safe in the
        // Keychain — a failed write leaves the plaintext file exactly as it was, so the data
        // isn't lost, and the next launch (with a working Keychain) will retry.
        let rewritten = try String(contentsOf: configFile, encoding: .utf8)
        #expect(rewritten == originalContents)
        #expect(rewritten.contains("sk-legacy-plaintext"))
    }

    /// Guards against a real data-loss path: if the launch-time migration fails (Keychain write
    /// error) the plaintext key is left sitting in config.json, but `Config`/`SummaryConfig` have
    /// no `apiKey` field to carry it — so any ordinary `save()` (e.g. Settings' Save button,
    /// touched for something unrelated) would silently and permanently wipe the only copy of the
    /// key the moment it re-encodes and overwrites the file. `save()` must retry the migration
    /// against the still-on-disk plaintext before every write, so a transient Keychain failure
    /// doesn't turn into permanent loss the next time anything calls `save()`.
    @Test func saveRetriesFailedMigrationBeforeOverwritingConfig() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let configFile = dir.appendingPathComponent("config.json")
        try legacyConfigJSON(apiKey: "sk-legacy-plaintext").write(to: configFile, atomically: true, encoding: .utf8)

        let keychain = FakeKeychainStore()
        keychain.setError = KeychainError.unexpectedStatus(-1)
        let manager = ConfigManager(configDir: dir, keychainStore: keychain)

        // Migration failed at launch: key is still nowhere but the plaintext file.
        #expect(SummaryAPIKeyStore.load(keychain: keychain) == "")
        #expect(try String(contentsOf: configFile, encoding: .utf8).contains("sk-legacy-plaintext"))

        // The Keychain issue clears up (e.g. transient), and something unrelated triggers a save
        // — this must not be the moment the plaintext key gets clobbered for good.
        keychain.setError = nil
        manager.update { $0.silenceTimeoutMinutes = 9 }

        #expect(SummaryAPIKeyStore.load(keychain: keychain) == "sk-legacy-plaintext")
        let rewritten = try String(contentsOf: configFile, encoding: .utf8)
        #expect(!rewritten.contains("sk-legacy-plaintext"))
        #expect(!rewritten.contains("api_key"))
    }
}
