import Foundation

/// A snapshot of a downloaded model: which Hugging Face commit it came from,
/// when it was downloaded, and the SHA-256 of every file under the cache root.
///
/// Persisted to `~/Library/Application Support/Parley/model-manifests/<repo-slug>.json` after a
/// successful download. Used to (a) detect local corruption, (b) compare against
/// the current Hugging Face commit when the user opts in to update checks.
public struct ModelManifest: Codable, Equatable, Sendable {
    /// Hugging Face repo slug, e.g. "FluidInference/parakeet-tdt-0.6b-v3-coreml".
    public let repo: String
    /// Top-level commit SHA from the HF API at download time.
    public let commitSha: String
    /// HF "lastModified" ISO-8601 string at download time. Informational only.
    public let lastModifiedISO: String?
    /// When we wrote this manifest locally.
    public let downloadedAt: Date
    /// Version string for the SDK used (best-effort label).
    public let sdkLabel: String
    /// Per-file integrity records. Paths are relative to the cache root.
    public let files: [FileEntry]

    public struct FileEntry: Codable, Equatable, Sendable {
        public let relativePath: String
        public let size: Int64
        public let sha256: String

        public init(relativePath: String, size: Int64, sha256: String) {
            self.relativePath = relativePath
            self.size = size
            self.sha256 = sha256
        }
    }

    public init(
        repo: String,
        commitSha: String,
        lastModifiedISO: String?,
        downloadedAt: Date,
        sdkLabel: String,
        files: [FileEntry]
    ) {
        self.repo = repo
        self.commitSha = commitSha
        self.lastModifiedISO = lastModifiedISO
        self.downloadedAt = downloadedAt
        self.sdkLabel = sdkLabel
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case repo
        case commitSha = "commit_sha"
        case lastModifiedISO = "last_modified"
        case downloadedAt = "downloaded_at"
        case sdkLabel = "sdk_label"
        case files
    }
}

/// Result of comparing a manifest against the local cache contents.
///
/// Reports missing and corrupt files *together* in a single pass — `verify()` scans
/// every file before returning, so a cache that is both missing some files and has
/// corrupted others surfaces both sets at once instead of short-circuiting on the first.
public struct ManifestVerification: Equatable, Sendable {
    /// Whether a manifest existed to verify against at all. `false` means first run,
    /// or the model was never downloaded through a build that wrote manifests.
    public let manifestPresent: Bool
    /// Listed files absent from the cache.
    public let missing: [String]
    /// Files present but with the wrong size or SHA-256.
    public let corrupt: [String]

    public init(manifestPresent: Bool, missing: [String], corrupt: [String]) {
        self.manifestPresent = manifestPresent
        self.missing = missing
        self.corrupt = corrupt
    }

    /// No manifest exists yet (first run, or never downloaded with manifest support).
    public static let noManifest = ManifestVerification(manifestPresent: false, missing: [], corrupt: [])
    /// All files match the manifest.
    public static let ok = ManifestVerification(manifestPresent: true, missing: [], corrupt: [])

    /// A manifest exists and every listed file matches.
    public var isOK: Bool { manifestPresent && missing.isEmpty && corrupt.isEmpty }
    /// A manifest exists but one or more files are missing or corrupt.
    public var hasProblems: Bool { manifestPresent && (!missing.isEmpty || !corrupt.isEmpty) }
}

/// Result of checking Hugging Face for a newer commit than the one in the manifest.
public enum ManifestUpdateStatus: Equatable, Sendable {
    /// HF reports the same commit SHA we recorded at download.
    case upToDate(commitSha: String)
    /// HF reports a different commit SHA. The user can choose to clear the cache and re-download.
    case updateAvailable(localCommitSha: String, remoteCommitSha: String, remoteLastModifiedISO: String?)
    /// We have no manifest to compare against — usually means the model was never downloaded
    /// through a build that wrote manifests. Treat as "unknown" and prompt re-download to establish baseline.
    case noBaseline
    /// The check could not complete (offline, HF unreachable, parse error, etc.).
    case checkFailed(reason: String)
}
