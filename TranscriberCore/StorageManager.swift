import Foundation
import os

/// Enforces audio archive storage quota by deleting oldest .m4a files.
/// Only manages .m4a files — transcripts (JSON/SRT/TXT) and WAVs are never touched.
public enum StorageManager {

    /// Calculate quota in bytes from hours and bitrate.
    public static func quotaBytes(hours: Int, bitrateKbps: Int) -> Int {
        hours * bitrateKbps * 1000 / 8 * 3600
    }

    /// Find all .m4a files recursively under a directory — nil when `stop` said to stop before the walk was done.
    private static func findM4aFiles(in directory: URL, stop: () -> Bool = { false }) -> [URL]? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            if stop() { return nil }
            if url.pathExtension == "m4a" { results.append(url) }
        }
        return results
    }

    /// Total size of .m4a files in the directory (recursive).
    public static func currentUsageBytes(in directory: URL) -> Int {
        (findM4aFiles(in: directory) ?? [])
            .compactMap { url -> Int? in
                (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            }
            .reduce(0, +)
    }

    /// What a quota pass did: the files it deleted, and by how much the protected files alone still
    /// keep usage over the quota (0 when they don't) — never silent (round 8 item 2). `finished` is false when the pass
    /// stopped at its deadline (L review 251): the overrun is then unknown (0).
    public struct QuotaReport: Sendable {
        public let deleted: [URL]
        public let protectedOverrunBytes: Int
        public var finished = true
    }

    /// Enforce storage quota by deleting oldest .m4a files (recursive scan), never `protectedFile`.
    @discardableResult
    public static func enforceQuota(
        in directory: URL,
        limitHours: Int,
        bitrateKbps: Int,
        protectedFile: URL?
    ) throws -> [URL] {
        try enforceQuota(in: directory, limitHours: limitHours, bitrateKbps: bitrateKbps, protectedFiles: protectedFile.map { [$0] } ?? [])
    }

    /// Enforce storage quota by deleting oldest .m4a files (recursive scan), never one of
    /// `protectedFiles` — every file backing the record being written (round 7 item 1).
    @discardableResult
    public static func enforceQuota(
        in directory: URL,
        limitHours: Int,
        bitrateKbps: Int,
        protectedFiles: [URL]
    ) throws -> [URL] {
        try enforceQuotaReport(in: directory, limitHours: limitHours, bitrateKbps: bitrateKbps, protectedFiles: protectedFiles).deleted
    }

    /// `enforceQuota`, reporting what the protected files alone leave over the quota. `deadline` (L review 251): the pass
    /// stops walking there — a walk cut short deletes nothing (it has not weighed every archive, so it cannot know the
    /// oldest), and one stopped among its deletes keeps what is left. Either way the report says it did not finish.
    public static func enforceQuotaReport(
        in directory: URL,
        limitHours: Int,
        bitrateKbps: Int,
        protectedFiles: [URL],
        deadline: SuspendingClock.Instant? = nil
    ) throws -> QuotaReport {
        let quota = quotaBytes(hours: limitHours, bitrateKbps: bitrateKbps)
        let pastDeadline = { deadline.map { SuspendingClock.now >= $0 } ?? false }

        guard var m4aFiles = findM4aFiles(in: directory, stop: pastDeadline) else {
            Logger.files.error("StorageManager: the quota pass reached its deadline before it had weighed every archive — nothing deleted")
            return QuotaReport(deleted: [], protectedOverrunBytes: 0, finished: false)
        }

        // Sort oldest first
        m4aFiles.sort { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return dateA < dateB
        }

        var totalSize = m4aFiles.compactMap { url -> Int? in
            (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }.reduce(0, +)

        guard totalSize > quota else { return QuotaReport(deleted: [], protectedOverrunBytes: 0) }

        let resolvedProtected = Set(protectedFiles.map { $0.resolvingSymlinksInPath().path })

        var deleted: [URL] = []
        var finished = true
        for file in m4aFiles {
            guard totalSize > quota else { break }
            guard !pastDeadline() else {
                Logger.files.error("StorageManager: the quota pass reached its deadline — \(deleted.count, privacy: .public) file(s) deleted, the rest left for the next pass")
                finished = false
                break
            }
            if resolvedProtected.contains(file.resolvingSymlinksInPath().path) { continue }

            let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            try FileManager.default.removeItem(at: file)
            totalSize -= fileSize
            deleted.append(file)
            Logger.files.info("StorageManager: deleted \(file.lastPathComponent, privacy: .sensitive) (\(fileSize) bytes) to enforce quota")
        }

        if !deleted.isEmpty {
            Logger.files.info("StorageManager: deleted \(deleted.count) file(s), usage now \(totalSize) / \(quota) bytes")
        }
        // Everything deletable is gone and usage is still over: the protected files alone overrun it.
        guard finished else { return QuotaReport(deleted: deleted, protectedOverrunBytes: 0, finished: false) }
        let overrun = max(0, totalSize - quota)
        if overrun > 0 {
            Logger.files.info("StorageManager: protected audio alone keeps usage \(overrun) bytes over the quota — nothing more may be deleted")
        }
        return QuotaReport(deleted: deleted, protectedOverrunBytes: overrun)
    }
}
