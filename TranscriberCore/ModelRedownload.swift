import Foundation

/// Re-downloads a model into a staging folder beside its cache and swaps it in only once the
/// download is complete (#349): a failed, cancelled or partial download never removes the working
/// model, so a re-download can never leave the app without one.
public enum ModelRedownload {
    /// Prefix of the staging folders, created next to the cache folder (same volume, so the swap is a rename).
    static let stagingPrefix = ".parley-redownload-"

    /// - Parameters:
    ///   - cacheDir: the model's cache folder (e.g. `…/FluidAudio/Models/parakeet-tdt-0.6b-v3`).
    ///   - download: fetches the model into the folder it is given, which has `cacheDir`'s name.
    ///   - isComplete: whether a folder holds a complete model.
    public static func run(
        cacheDir: URL,
        download: (URL) async throws -> Void,
        isComplete: (URL) -> Bool
    ) async throws {
        let fm = FileManager.default
        let parent = cacheDir.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        removeLeftoverStaging(in: parent)
        let stagingRoot = parent.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        let staged = stagingRoot.appendingPathComponent(cacheDir.lastPathComponent, isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        try await download(staged)
        try Task.checkCancellation()
        guard isComplete(staged) else { throw ModelRedownloadError.incomplete }

        do {
            if fm.fileExists(atPath: cacheDir.path) {
                _ = try fm.replaceItemAt(cacheDir, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: cacheDir)
            }
        } catch {
            throw ModelRedownloadError.swapFailed(error.localizedDescription)
        }
    }

    /// A staging folder left by a re-download the app did not live to finish (hundreds of MB).
    private static func removeLeftoverStaging(in parent: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(stagingPrefix) {
            try? fm.removeItem(at: parent.appendingPathComponent(name))
        }
    }
}

public enum ModelRedownloadError: LocalizedError, Equatable {
    case incomplete
    /// The download was complete but putting it in place failed: the cache may hold either model, or neither.
    case swapFailed(String)

    public var errorDescription: String? {
        switch self {
        case .incomplete: return "The downloaded model is incomplete."
        case .swapFailed(let reason): return "Replacing the model failed (\(reason))."
        }
    }

    /// Whether the cache is known to still hold the model it had before the re-download started.
    public var keptCurrentModel: Bool {
        switch self {
        case .incomplete: return true
        case .swapFailed: return false
        }
    }
}
