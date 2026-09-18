import Foundation
import Observation
import os

@Observable
public final class ConfigManager {
    public static let shared = ConfigManager()

    private let configDir: URL
    private let configFile: URL
    private let keychainStore: KeychainStoring

    public private(set) var config: Config

    public init(configDir: URL? = nil, keychainStore: KeychainStoring = KeychainStore.shared) {
        let dir = configDir ?? AppPaths.dataDirectory
        self.configDir = dir
        self.configFile = dir.appendingPathComponent("config.json")
        self.keychainStore = keychainStore
        // #48: move a legacy plaintext `summary.api_key` out of config.json and into the Keychain
        // before the file is ever decoded, so a config written by a pre-#48 build never leaves a
        // real credential sitting in plaintext on disk past this launch.
        Self.migrateAPIKeyIfNeeded(at: self.configFile, keychain: keychainStore)
        self.config = Self.load(from: self.configFile)
    }

    private static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else {
            Logger.config.info("Config not found or invalid, using defaults")
            return .default
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["sample_rate"] != nil {
            Logger.config.warning("Config field 'sample_rate' is deprecated and ignored — system audio is captured at 48 kHz")
        }
        if let share = config.diarizationMinSpeakerShare,
           share > DiarizationCleanup.maxSensibleShare {
            Logger.config.warning(
                "diarization_min_speaker_share \(share, privacy: .public) exceeds the \(DiarizationCleanup.maxSensibleShare, privacy: .public) ceiling — at that level a real participant is absorbed, not a fragment. Using the \(DiarizationCleanup.defaultMinShare, privacy: .public) default instead."
            )
        }
        Logger.config.info("Config loaded — format: \(config.outputFormat, privacy: .public), engine: \(config.engine.rawValue, privacy: .public)")
        return config
    }

    public func save() {
        try? FileManager.default.createDirectory(
            at: configDir, withIntermediateDirectories: true
        )
        // #48: if the launch-time migration above failed (e.g. a transient Keychain error), the
        // on-disk file may still be carrying a plaintext `summary.api_key` that `Config` itself
        // no longer has a field for. Retry the migration against the current file before every
        // write, so an ordinary `save()` (e.g. from Settings) can't clobber that plaintext key
        // with a freshly encoded `Config` before it's ever made it into the Keychain. Idempotent
        // and near-free once migrated, so unconditional here is fine (see migrateAPIKeyIfNeeded).
        Self.migrateAPIKeyIfNeeded(at: configFile, keychain: keychainStore)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configFile, options: .atomic)
        Logger.config.debug("Config saved")
    }

    public func update(_ transform: (inout Config) -> Void) {
        transform(&config)
        save()
    }

    /// Moves a legacy plaintext `summary.api_key` out of `config.json` and into the Keychain
    /// (#48). Operates on the raw JSON, not `Config`/`SummaryConfig` — those types no longer have
    /// an `apiKey` field at all, so a plain `Codable` decode would silently drop the value rather
    /// than migrate it.
    ///
    /// Idempotent by construction: once `api_key` is gone from the file this is a no-op, so it is
    /// safe (and simplest) to run on every launch rather than gating on a "did we migrate"
    /// marker. If the Keychain write fails, the JSON is left completely untouched — the key must
    /// never be cleared from disk before it is confirmed safe in the Keychain.
    @discardableResult
    static func migrateAPIKeyIfNeeded(at url: URL, keychain: KeychainStoring) -> Bool {
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var summaryJSON = json["summary"] as? [String: Any],
              let plaintextKey = summaryJSON["api_key"] as? String,
              !plaintextKey.isEmpty
        else {
            return false
        }

        // The Keychain is authoritative the moment it holds anything for this key. If an earlier
        // migration attempt wrote the key successfully but failed to strip config.json afterward
        // (write-back failure below), or if Settings has since saved a newer key directly, this
        // function can be reached again with a stale plaintext value still sitting on disk. Never
        // let that stale value clobber whatever's already in the Keychain — only write when the
        // Keychain doesn't have a value for this (service, account) yet.
        let alreadyInKeychain = (try? keychain.get(service: SummaryAPIKeyStore.service, account: SummaryAPIKeyStore.account)) != nil
        if !alreadyInKeychain {
            do {
                try keychain.set(plaintextKey, service: SummaryAPIKeyStore.service, account: SummaryAPIKeyStore.account)
            } catch {
                Logger.config.error("Failed to migrate summary API key to Keychain — leaving config.json untouched, will retry next launch: \(String(describing: error), privacy: .public)")
                return false
            }
        }

        // Reachable once the Keychain is confirmed to hold a value for this key — either just
        // written above, or already there from a prior attempt/Settings save. Either way it's now
        // safe to strip the stale plaintext copy out of config.json.
        summaryJSON.removeValue(forKey: "api_key")
        json["summary"] = summaryJSON
        guard let rewritten = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            Logger.config.error("Migrated summary API key to Keychain but failed to serialize config.json — will retry next launch")
            return false
        }
        do {
            try rewritten.write(to: url, options: .atomic)
        } catch {
            Logger.config.error("Migrated summary API key to Keychain but failed to write config.json — will retry next launch: \(String(describing: error), privacy: .public)")
            return false
        }

        Logger.config.info("Migrated summary API key from config.json to Keychain")
        return true
    }
}
