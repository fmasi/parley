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
public enum ManifestVerification: Equatable, Sendable {
    /// All files match the manifest.
    case ok
    /// No manifest exists yet (first run, or never downloaded with manifest support).
    case noManifest
    /// One or more listed files are missing from the cache.
    case missing(paths: [String])
    /// One or more files exist but have wrong size or SHA-256.
    case corrupt(paths: [String])
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
