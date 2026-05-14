import Foundation

public enum AppVersion {

    /// Tag-based version: "0.6.1". Falls back to "dev" when not bundled.
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Full git description: "v0.6.1-12-ga3f9c12". Falls back to "unknown".
    public static var gitDescription: String {
        Bundle.main.infoDictionary?["ATGitDescription"] as? String ?? "unknown"
    }

    /// Short commit hash parsed from gitDescription: "a3f9c12".
    public static var commitHash: String? {
        parseCommitHash(from: gitDescription)
    }

    /// Human-friendly string for About panel: "0.6.1 (a3f9c12)".
    public static var displayString: String {
        formatDisplay(version: version, gitDescription: gitDescription)
    }

    // MARK: - Parsing (internal, exposed for testing)

    /// Extract short commit hash from git describe output.
    /// "v0.6.1-12-ga3f9c12" -> "a3f9c12"
    /// "a3f9c12-dirty" -> "a3f9c12"
    /// "v0.7.0" -> nil (on tag, no hash in string)
    static func parseCommitHash(from description: String) -> String? {
        let parts = description.split(separator: "-")
        for (i, part) in parts.enumerated() {
            if part.hasPrefix("g"), part.count >= 7,
               part.dropFirst().allSatisfy(\.isHexDigit) {
                return String(part.dropFirst())
            }
            // Bare hash (no tags): "a3f9c12" or "a3f9c12-dirty"
            if i == 0, !part.contains("."),
               part.count >= 7, part.allSatisfy(\.isHexDigit) {
                return String(part)
            }
        }
        return nil
    }

    /// Extract commit distance from tag.
    /// "v0.6.1-12-ga3f9c12" -> 12
    /// "v0.7.0" -> 0 (on tag)
    /// "a3f9c12" -> nil (no tag)
    static func parseCommitDistance(from description: String) -> Int? {
        let parts = description.split(separator: "-")
        // Exactly on a tag: "v0.7.0"
        if parts.count == 1 && parts[0].contains(".") {
            return 0
        }
        // "v0.6.1-12-ga3f9c12[-dirty]"
        if parts.count >= 3,
           let distance = Int(parts[parts.count >= 4 && parts.last == "dirty" ? parts.count - 3 : parts.count - 2]) {
            return distance
        }
        return nil
    }

    /// Format display string from version and git description.
    static func formatDisplay(version: String, gitDescription: String) -> String {
        if gitDescription == "unknown" { return version }

        let isDirty = gitDescription.hasSuffix("-dirty")

        guard let hash = parseCommitHash(from: gitDescription) else {
            // Exactly on tag, clean
            return version
        }

        let suffix = isDirty ? "\(hash)-dirty" : hash
        return "\(version) (\(suffix))"
    }
}
