import Foundation
import os

/// Enforces audio archive storage quota by deleting oldest .m4a files.
/// Only manages .m4a files — transcripts (JSON/SRT/TXT) and WAVs are never touched.
public enum StorageManager {

    /// Calculate quota in bytes from hours and bitrate.
    public static func quotaBytes(hours: Int, bitrateKbps: Int) -> Int {
        hours * bitrateKbps * 1000 / 8 * 3600
    }

    /// Total size of .m4a files in the directory.
    public static func currentUsageBytes(in directory: URL) -> Int {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        return contents
            .filter { $0.pathExtension == "m4a" }
            .compactMap { url -> Int? in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                return values?.fileSize
            }
            .reduce(0, +)
    }

    /// Enforce storage quota by deleting oldest .m4a files.
    @discardableResult
    public static func enforceQuota(
        in directory: URL,
        limitHours: Int,
        bitrateKbps: Int,
        protectedFile: URL?
    ) throws -> [URL] {
        let quota = quotaBytes(hours: limitHours, bitrateKbps: bitrateKbps)
        let fm = FileManager.default
        // Enumerate filenames only, then reconstruct URLs from the caller-supplied directory
        // so returned paths match the caller's URL prefix (avoids /var vs /private/var mismatch).
        guard let filenames = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }

        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        var m4aFiles = filenames
            .filter { ($0 as NSString).pathExtension == "m4a" }
            .map { directory.appendingPathComponent($0) }

        m4aFiles.sort { a, b in
            let dateA = (try? a.resourceValues(forKeys: resourceKeys))?.contentModificationDate ?? .distantPast
            let dateB = (try? b.resourceValues(forKeys: resourceKeys))?.contentModificationDate ?? .distantPast
            return dateA < dateB
        }

        var totalSize = m4aFiles.compactMap { url -> Int? in
            (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }.reduce(0, +)

        guard totalSize > quota else { return [] }

        let resolvedProtected = protectedFile.map { $0.resolvingSymlinksInPath().path }

        var deleted: [URL] = []
        for file in m4aFiles {
            guard totalSize > quota else { break }
            if let resolvedProtected,
               file.resolvingSymlinksInPath().path == resolvedProtected { continue }

            let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            try fm.removeItem(at: file)
            totalSize -= fileSize
            deleted.append(file)
            Logger.files.info("StorageManager: deleted \(file.lastPathComponent, privacy: .public) (\(fileSize) bytes) to enforce quota")
        }

        if !deleted.isEmpty {
            Logger.files.info("StorageManager: deleted \(deleted.count) file(s), usage now \(totalSize) / \(quota) bytes")
        }

        return deleted
    }
}
