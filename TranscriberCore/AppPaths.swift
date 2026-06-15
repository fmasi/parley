import Foundation

/// Central source of truth for Parley's on-disk locations.
///
/// The data directory moved from the legacy `~/.audio-transcribe` dotfolder to
/// the macOS-idiomatic `~/Library/Application Support/Parley`. `dataDirectory`
/// performs a one-time migration on first access so existing `config.json`,
/// `recording.json`, `token-ratios.json`, and model manifests carry over.
public enum AppPaths {

    /// `~/Library/Application Support/Parley`, migrated from `~/.audio-transcribe`
    /// on first access. Resolved once per process.
    public static let dataDirectory: URL = resolveDataDirectory(
        preferred: defaultPreferredDirectory(),
        legacy: defaultLegacyDirectory(),
        fileManager: .default
    )

    static func defaultPreferredDirectory() -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Parley")
    }

    static func defaultLegacyDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".audio-transcribe")
    }

    /// Resolve the data directory, migrating `legacy` → `preferred` if needed.
    /// - If `preferred` already exists, return it (no migration — it wins).
    /// - Else if `legacy` exists, move it to `preferred` and return `preferred`.
    /// - Else create `preferred` fresh and return it.
    @discardableResult
    static func resolveDataDirectory(preferred: URL, legacy: URL, fileManager: FileManager) -> URL {
        if fileManager.fileExists(atPath: preferred.path) {
            return preferred
        }
        // Ensure the parent (Application Support) exists before any move/create.
        try? fileManager.createDirectory(
            at: preferred.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: legacy.path) {
            do {
                try fileManager.moveItem(at: legacy, to: preferred)
                return preferred
            } catch {
                // Migration failed — fall through and create a fresh directory.
            }
        }
        try? fileManager.createDirectory(at: preferred, withIntermediateDirectories: true)
        return preferred
    }
}
