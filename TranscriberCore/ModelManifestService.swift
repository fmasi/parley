import Foundation
import CryptoKit
import os

/// Records, verifies and (optionally) checks-for-updates the manifest for a downloaded
/// Hugging Face model. The manifest is what gives us a forensic record of *which* model
/// version is currently on disk, and lets us detect both local corruption and upstream
/// changes that would otherwise be invisible because FluidAudio's cache is filename-keyed.
///
/// All on-disk operations are local. The only network call is `checkForUpdate(...)`,
/// which the caller must opt into — never invoked from `record(...)` or `verify(...)`.
public actor ModelManifestService {
    public static let shared = ModelManifestService()

    private let manifestDir: URL
    private let session: URLSession

    public init(
        manifestDir: URL? = nil,
        session: URLSession = .shared
    ) {
        let dir = manifestDir ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".audio-transcribe")
            .appendingPathComponent("model-manifests")
        self.manifestDir = dir
        self.session = session
    }

    // MARK: - Recording

    /// Walk the cache directory, hash every file, query HF for the current commit,
    /// and persist a manifest. Idempotent — safe to call after every download.
    public func record(repo: String, cacheRoot: URL, sdkLabel: String) async throws -> ModelManifest {
        let files = try Self.hashAllFiles(under: cacheRoot)
        var commitSha = ""
        var lastModifiedISO: String? = nil
        do {
            let head = try await fetchRepoHead(repo: repo)
            commitSha = head.sha
            lastModifiedISO = head.lastModified
        } catch {
            Logger.config.warning("Manifest: HF head lookup failed (\(error.localizedDescription, privacy: .public)) — recording manifest with empty commit SHA")
        }
        let manifest = ModelManifest(
            repo: repo,
            commitSha: commitSha,
            lastModifiedISO: lastModifiedISO,
            downloadedAt: Date(),
            sdkLabel: sdkLabel,
            files: files
        )
        try writeManifest(manifest)
        Logger.config.info("Manifest recorded for \(repo, privacy: .public): \(files.count) files, commit=\(commitSha, privacy: .public)")
        return manifest
    }

    // MARK: - Reading & verifying

    public func loadManifest(for repo: String) -> ModelManifest? {
        let url = manifestURL(for: repo)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ModelManifest.self, from: data)
    }

    /// Re-hash files in `cacheRoot` and compare against the recorded manifest.
    /// Returns `.noManifest` if no manifest exists for `repo`.
    public func verify(repo: String, cacheRoot: URL) async -> ManifestVerification {
        guard let manifest = loadManifest(for: repo) else { return .noManifest }
        var missing: [String] = []
        var corrupt: [String] = []
        for entry in manifest.files {
            let fileURL = cacheRoot.appendingPathComponent(entry.relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                missing.append(entry.relativePath)
                continue
            }
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
                if size != entry.size {
                    corrupt.append(entry.relativePath)
                    continue
                }
                let actualSha = try Self.sha256(of: fileURL)
                if actualSha != entry.sha256 {
                    corrupt.append(entry.relativePath)
                }
            } catch {
                corrupt.append(entry.relativePath)
            }
        }
        if !missing.isEmpty { return .missing(paths: missing) }
        if !corrupt.isEmpty { return .corrupt(paths: corrupt) }
        return .ok
    }

    // MARK: - Online update check (opt-in)

    /// Query Hugging Face for the current commit SHA and compare to the manifest.
    /// Network-only. The caller must gate this on user consent (Settings toggle).
    public func checkForUpdate(repo: String) async -> ManifestUpdateStatus {
        guard let manifest = loadManifest(for: repo) else { return .noBaseline }
        guard !manifest.commitSha.isEmpty else { return .noBaseline }
        do {
            let head = try await fetchRepoHead(repo: repo)
            if head.sha == manifest.commitSha {
                return .upToDate(commitSha: head.sha)
            }
            return .updateAvailable(
                localCommitSha: manifest.commitSha,
                remoteCommitSha: head.sha,
                remoteLastModifiedISO: head.lastModified
            )
        } catch {
            return .checkFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - Internals

    private struct RepoHead {
        let sha: String
        let lastModified: String?
    }

    /// HF response shape we care about. Other fields are ignored.
    private struct HFRepoResponse: Decodable {
        let sha: String
        let lastModified: String?
    }

    private func fetchRepoHead(repo: String) async throws -> RepoHead {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)") else {
            throw ManifestError.invalidRepo(repo)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ManifestError.httpError(status: http.statusCode)
        }
        let decoded = try JSONDecoder().decode(HFRepoResponse.self, from: data)
        return RepoHead(sha: decoded.sha, lastModified: decoded.lastModified)
    }

    private func manifestURL(for repo: String) -> URL {
        manifestDir.appendingPathComponent(Self.slug(for: repo) + ".json")
    }

    private func writeManifest(_ manifest: ModelManifest) throws {
        try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(for: manifest.repo), options: .atomic)
    }

    static func slug(for repo: String) -> String {
        repo.replacingOccurrences(of: "/", with: "_")
    }

    /// Recursive SHA-256 walk. Skips symlinks. Hidden files (e.g. .DS_Store) included
    /// — their inclusion is intentional so we record the on-disk reality, not a curated subset.
    static func hashAllFiles(under root: URL) throws -> [ModelManifest.FileEntry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) else {
            throw ManifestError.cacheUnreadable(root)
        }
        var entries: [ModelManifest.FileEntry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            let sha = try sha256(of: url)
            let relative = url.path.replacingOccurrences(of: root.path, with: "").trimmingPrefix("/")
            entries.append(ModelManifest.FileEntry(
                relativePath: String(relative),
                size: size,
                sha256: sha
            ))
        }
        // Stable order so manifests round-trip predictably across runs.
        entries.sort { $0.relativePath < $1.relativePath }
        return entries
    }

    /// Streaming SHA-256 of a file, in 1 MiB chunks. Avoids loading large weights into RAM.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20  // 1 MiB
        while true {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum ManifestError: LocalizedError {
    case invalidRepo(String)
    case httpError(status: Int)
    case cacheUnreadable(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidRepo(let r): return "Invalid Hugging Face repo slug: \(r)"
        case .httpError(let s):   return "Hugging Face API returned HTTP \(s)"
        case .cacheUnreadable(let u): return "Cannot enumerate cache directory: \(u.path)"
        }
    }
}
