import Foundation
import os

/// Enforces audio archive storage quota by deleting oldest .m4a files.
/// Only manages .m4a files — transcripts (JSON/SRT/TXT) and WAVs are never touched.
public enum StorageManager {

    /// Calculate quota in bytes from hours and bitrate.
    public static func quotaBytes(hours: Int, bitrateKbps: Int) -> Int {
        hours * bitrateKbps * 1000 / 8 * 3600
    }

    /// Find all .m4a files recursively under a directory.
    private static func findM4aFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "m4a" {
            results.append(url)
        }
        return results
    }

    /// Total size of .m4a files in the directory (recursive).
    public static func currentUsageBytes(in directory: URL) -> Int {
        findM4aFiles(in: directory)
            .compactMap { url -> Int? in
                (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            }
            .reduce(0, +)
    }

    /// Enforce storage quota by deleting oldest .m4a files (recursive scan).
    @discardableResult
    public static func enforceQuota(
        in directory: URL,
        limitHours: Int,
        bitrateKbps: Int,
        protectedFile: URL?
    ) throws -> [URL] {
        let quota = quotaBytes(hours: limitHours, bitrateKbps: bitrateKbps)

        var m4aFiles = findM4aFiles(in: directory)

        // Sort oldest first
        m4aFiles.sort { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
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
            try FileManager.default.removeItem(at: file)
            totalSize -= fileSize
            deleted.append(file)
            Logger.files.info("StorageManager: deleted \(file.lastPathComponent, privacy: .private) (\(fileSize) bytes) to enforce quota")
        }

        if !deleted.isEmpty {
            Logger.files.info("StorageManager: deleted \(deleted.count) file(s), usage now \(totalSize) / \(quota) bytes")
        }

        return deleted
    }
}
