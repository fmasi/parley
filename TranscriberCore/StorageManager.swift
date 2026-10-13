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

    /// Where a quota pass weighs the archives (#224).
    public enum QuotaScope: Equatable, Sendable {
        /// The whole recordings tree: every `yyyy-MM-dd` day folder of the configured recording root. Every `.m4a` in it
        /// counts towards the limit (what Settings shows); only Parley's archives — named by the session rule, directly in
        /// a day folder — may be deleted.
        case tree(URL)
        /// One folder alone, recursively, every `.m4a` in it a candidate: what every pass did before #224, and still what
        /// a chunk's pass does, and a pass for a folder that is not a day folder of the root (a CLI run elsewhere, a test).
        case folder(URL)
    }

    /// The scope of a pass after a recording wrote into `folder` (#224): the whole tree when `folder` is, lexically, a day
    /// folder directly under `recordingRoot` — nothing on disk is read to decide it; anything else stays `folder` alone.
    public static func quotaScope(for folder: URL, recordingRoot: String) -> QuotaScope {
        let root = URL(fileURLWithPath: (recordingRoot as NSString).expandingTildeInPath, isDirectory: true).standardized
        let folder = folder.standardized
        guard isDayFolderName(folder.lastPathComponent),
              folder.deletingLastPathComponent().standardized.path == root.path else { return .folder(folder) }
        return .tree(URL(fileURLWithPath: root.path))
    }

    /// `yyyy-MM-dd`: the day folders a recording start makes (`RecordingCoordinator.startNaming`).
    static func isDayFolderName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 && zip(parts, [4, 2, 2]).allSatisfy { $0.count == $1 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// A Parley archive's name: `HHmmss.m4a` or `HHmmss-<anything>.m4a` — a session id (a start time, then the typed name)
    /// with its chunk or segment suffix, or a merged file. Nothing else in the tree is ever deleted.
    static func isArchiveName(_ name: String) -> Bool {
        guard name.hasSuffix(".m4a") else { return false }
        let stem = name.dropLast(".m4a".count)
        let time = stem.prefix(6)
        guard time.count == 6, time.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        let rest = stem.dropFirst(6)
        return rest.isEmpty || (rest.first == "-" && rest.count > 1)
    }

    /// Every `.m4a` in the tree, and whether each is a candidate (#224): a Parley archive directly in a day folder. The walk
    /// does not follow a day folder that is a symbolic link — as `currentUsageBytes` does not. nil when `stop` said to stop.
    static func treeArchives(in root: URL, stop: () -> Bool) -> [(url: URL, candidate: Bool)]? {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var results: [(url: URL, candidate: Bool)] = []
        for case let url as URL in enumerator {
            if stop() { return nil }
            guard url.pathExtension == "m4a" else { continue }
            let candidate = enumerator.level == 2 && isDayFolderName(url.deletingLastPathComponent().lastPathComponent)
                && isArchiveName(url.lastPathComponent)
            results.append((url, candidate))
        }
        return results
    }

    /// What a quota pass did: the files it deleted, and by how much the files it may not delete — protected, in flight, or
    /// (in the tree) not Parley's archives — still keep usage over the quota (0 when they don't): never silent (round 8
    /// item 2). `finished` is false when the pass stopped at its deadline (L review 251): the overrun is then unknown (0).
    public struct QuotaReport: Sendable {
        public let deleted: [URL]
        public let protectedOverrunBytes: Int
        public var finished = true
        /// The recordings whose audio this pass deleted (#224), one entry per recording however many of its files went:
        /// `<day folder>/<transcript file>` for a transcript that listed them (it now carries an `audio_removed` mark), or
        /// `<day folder>/<archive stem>` when no transcript lists the file. Sorted.
        public var removedRecordings: [String] = []
        /// Why the files it did not delete were kept (#294), when they keep usage over the quota; empty otherwise.
        public var kept: Set<QuotaKept> = []

        /// The overrun in words, for the record's `quota_exceeded_by_current_session` issue and the log (#294): by how much,
        /// and whose audio keeps it — never another session's id (the record may be shared). nil when there is none.
        public var overrunDescription: String? {
            guard protectedOverrunBytes > 0 else { return nil }
            let reasons = QuotaKept.allCases.filter(kept.contains).map(\.wording)
            return "\(protectedOverrunBytes) bytes over the quota, kept by audio it may not delete: "
                + (reasons.isEmpty ? "unknown" : reasons.joined(separator: "; "))
        }
    }

    /// Why a quota pass kept a file (#294). The order is the order the record names them in.
    public enum QuotaKept: String, CaseIterable, Sendable {
        /// One of the files backing the record being written.
        case thisRecording
        /// An archive of another session that still has state in its folder (#230).
        case anotherRecording
        /// Every archive of a folder whose sessions cannot be told: a `session.json` / `session-*.json` whose id cannot be read
        /// (#230 (b)), or a folder that did not list.
        case unreadableSessionFile
        /// An `.m4a` in the tree that is not a Parley archive in a day folder (#224).
        case notParleyArchive
        /// A file the pass tried to delete and could not.
        case undeletable

        var wording: String {
            switch self {
            case .thisRecording: "this recording’s own"
            case .anotherRecording: "another recording’s, still being recorded or processed"
            case .unreadableSessionFile: "every archive in a folder whose session state Parley cannot read"
            case .notParleyArchive: "files that are not Parley recordings"
            case .undeletable: "files that could not be deleted"
            }
        }
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
    /// `protectedFiles` — every file backing the record being written (round 7 item 1) — nor an
    /// archive of any session that still has state in its folder (#230).
    @discardableResult
    public static func enforceQuota(
        in directory: URL,
        limitHours: Int,
        bitrateKbps: Int,
        protectedFiles: [URL]
    ) throws -> [URL] {
        try enforceQuotaReport(in: directory, limitHours: limitHours, bitrateKbps: bitrateKbps, protectedFiles: protectedFiles).deleted
    }

    /// `enforceQuotaReport` over one folder (`QuotaScope.folder`).
    public static func enforceQuotaReport(
        in directory: URL,
        limitHours: Int,
        bitrateKbps: Int,
        protectedFiles: [URL],
        deadline: SuspendingClock.Instant? = nil,
        sessionsWithState: (URL) -> Set<String>? = SessionState.sessionIdsWithState(in:)
    ) throws -> QuotaReport {
        try enforceQuotaReport(scope: .folder(directory), limitHours: limitHours, bitrateKbps: bitrateKbps, protectedFiles: protectedFiles,
                               deadline: deadline, sessionsWithState: sessionsWithState)
    }

    /// `enforceQuota`, reporting what the protected files alone leave over the quota. `deadline` (L review 251): the pass
    /// stops walking there — a walk cut short deletes nothing (it has not weighed every archive, so it cannot know the
    /// oldest), and one stopped among its deletes keeps what is left. Either way the report says it did not finish.
    /// `sessionsWithState`: a folder's in-flight sessions (#230); a parameter so a test can see when it is asked.
    /// Every transcript that listed a deleted file gets an `audio_removed` mark (#224), deadline or not: what was deleted
    /// is always recorded. A file that cannot be deleted is logged and skipped; the pass goes on.
    public static func enforceQuotaReport(
        scope: QuotaScope,
        limitHours: Int,
        bitrateKbps: Int,
        protectedFiles: [URL],
        deadline: SuspendingClock.Instant? = nil,
        sessionsWithState: (URL) -> Set<String>? = SessionState.sessionIdsWithState(in:)
    ) throws -> QuotaReport {
        let quota = quotaBytes(hours: limitHours, bitrateKbps: bitrateKbps)
        let pastDeadline = { deadline.map { SuspendingClock.now >= $0 } ?? false }

        let walked: [(url: URL, candidate: Bool)]?
        switch scope {
        case .tree(let root): walked = treeArchives(in: root, stop: pastDeadline)
        case .folder(let directory): walked = findM4aFiles(in: directory, stop: pastDeadline).map { $0.map { (url: $0, candidate: true) } }
        }
        guard var m4aFiles = walked else {
            Logger.files.error("StorageManager: the quota pass reached its deadline before it had weighed every archive — nothing deleted")
            return QuotaReport(deleted: [], protectedOverrunBytes: 0, finished: false)
        }

        // Sort oldest first
        m4aFiles.sort { a, b in
            let dateA = (try? a.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let dateB = (try? b.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return dateA < dateB
        }

        var totalSize = m4aFiles.compactMap { file -> Int? in
            (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }.reduce(0, +)

        guard totalSize > quota else { return QuotaReport(deleted: [], protectedOverrunBytes: 0) }

        let resolvedProtected = Set(protectedFiles.map { $0.resolvingSymlinksInPath().path })

        var deleted: [URL] = []
        var finished = true
        /// Why what was not deleted was kept (#294), and — for the log only — the other sessions it was kept for.
        var kept: Set<QuotaKept> = m4aFiles.contains { !$0.candidate } ? [.notParleyArchive] : []
        var keptFor: Set<String> = []
        /// Per folder, the sessions with state there; nil when that could not be told — nothing there is deleted then.
        var inFlightByFolder: [String: Set<String>?] = [:]
        for (file, candidate) in m4aFiles where candidate {
            guard totalSize > quota else { break }
            guard !pastDeadline() else {
                Logger.files.error("StorageManager: the quota pass reached its deadline — \(deleted.count, privacy: .public) file(s) deleted, the rest left for the next pass")
                finished = false
                break
            }
            if resolvedProtected.contains(file.resolvingSymlinksInPath().path) { kept.insert(.thisRecording); continue }
            // Nor another session's audio while that session still has state in the file's folder (#230): for its
            // chunks, the only copy. The folder is read here, once, and only now that a delete is about to happen.
            let folder = file.deletingLastPathComponent()
            let inFlight = inFlightByFolder[folder.path] ?? sessionsWithState(folder)
            inFlightByFolder.updateValue(inFlight, forKey: folder.path)
            guard let inFlight else { kept.insert(.unreadableSessionFile); continue }
            if let owner = inFlight.first(where: { CrashRecoveryPlanner.isArchive(file.lastPathComponent, of: $0) }) {
                kept.insert(.anotherRecording)
                keptFor.insert(owner)
                continue
            }

            let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                // Skipped, never the end of the pass: what it already deleted must still be marked (#224).
                Logger.files.error("StorageManager: could not delete \(file.lastPathComponent, privacy: .sensitive): \(error, privacy: .private)")
                kept.insert(.undeletable)
                continue
            }
            totalSize -= fileSize
            deleted.append(file)
            Logger.files.info("StorageManager: deleted \(file.lastPathComponent, privacy: .sensitive) (\(fileSize) bytes) to enforce quota")
        }

        var removed: [String] = []
        if !deleted.isEmpty {
            Logger.files.info("StorageManager: deleted \(deleted.count) file(s), usage now \(totalSize) / \(quota) bytes")
            removed = TranscriptAudioMark.mark(deleted: deleted, at: Date())
        }
        // Everything deletable is gone and usage is still over: the protected files alone overrun it.
        guard finished else { return QuotaReport(deleted: deleted, protectedOverrunBytes: 0, finished: false, removedRecordings: removed) }
        let overrun = max(0, totalSize - quota)
        guard overrun > 0 else { return QuotaReport(deleted: deleted, protectedOverrunBytes: 0, removedRecordings: removed) }
        let report = QuotaReport(deleted: deleted, protectedOverrunBytes: overrun, removedRecordings: removed, kept: kept)
        Logger.files.info("StorageManager: \(report.overrunDescription ?? "", privacy: .public) — nothing more may be deleted")
        if !keptFor.isEmpty {
            Logger.files.info("StorageManager: kept for the sessions still in flight: \(keptFor.sorted().joined(separator: ", "), privacy: .sensitive)")
        }
        return report
    }
}

/// The `audio_removed` mark (#224): a transcript whose audio the storage limit deleted says so in its metadata —
/// `{"at": <ISO 8601 time of the latest removal>, "files": [<file names, no paths>], "reason": "storage_limit"}` — and
/// nothing else in it changes: never its segments, never its `audio_files` / `audio_paths` (the record of what there was).
enum TranscriptAudioMark {
    static let key = "audio_removed"

    /// Mark the transcripts that list `deleted`, written durably, one write per transcript. Returns the recordings removed,
    /// sorted (`QuotaReport.removedRecordings`). A file no transcript lists, and a transcript that cannot be written, are
    /// logged: the deletion has happened either way.
    static func mark(deleted: [URL], at date: Date) -> [String] {
        let stamp = ISO8601DateFormatter().string(from: date)
        var recordings: Set<String> = []
        for (folderPath, files) in Dictionary(grouping: deleted, by: { $0.deletingLastPathComponent().path }) {
            let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
            let transcripts = self.transcripts(in: folder)
            var byTranscript: [URL: [String]] = [:]
            for file in files {
                let name = file.lastPathComponent
                if let listing = transcripts.first(where: { $0.audio.contains(name) }) {
                    byTranscript[listing.url, default: []].append(name)
                    recordings.insert("\(folder.lastPathComponent)/\(listing.url.lastPathComponent)")
                } else {
                    Logger.files.error("StorageManager: no transcript lists the deleted \(name, privacy: .sensitive) — nothing to mark")
                    recordings.insert("\(folder.lastPathComponent)/\(stem(of: name))")
                }
            }
            for (url, names) in byTranscript {
                do {
                    try write(names, into: url, at: stamp)
                } catch {
                    Logger.files.error("StorageManager: could not mark \(url.lastPathComponent, privacy: .sensitive) for its removed audio: \(error, privacy: .private)")
                }
            }
        }
        return recordings.sorted()
    }

    /// The transcripts in `folder` and the audio file names each lists (`audio_files`, and `audio_paths`' last components).
    /// A file that is not a readable transcript — `session.json`, a moved-aside state, anything else — is not one.
    private static func transcripts(in folder: URL) -> [(url: URL, audio: Set<String>)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json"), !name.hasPrefix("."), !name.hasPrefix("session") else { return nil }
            let url = folder.appendingPathComponent(name)
            guard let metadata = readTranscript(url)?["metadata"] as? [String: Any] else { return nil }
            let files = (metadata["audio_files"] as? [String] ?? [])
                + (metadata["audio_paths"] as? [String] ?? []).map { ($0 as NSString).lastPathComponent }
            return (url, Set(files))
        }
    }

    private static func readTranscript(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["metadata"] is [String: Any], json["segments"] is [[String: Any]] else { return nil }
        return json
    }

    /// Add `names` to the transcript's mark — after the files an earlier pass named — and write it durably.
    private static func write(_ names: [String], into url: URL, at stamp: String) throws {
        try TranscriptWrites.exclusive(url) { try writeUnlocked(names, into: url, at: stamp) }
    }

    private static func writeUnlocked(_ names: [String], into url: URL, at stamp: String) throws {
        guard var json = readTranscript(url), var metadata = json["metadata"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let earlier = (metadata[key] as? [String: Any])?["files"] as? [String] ?? []
        metadata[key] = ["at": stamp, "files": earlier + names.sorted().filter { !earlier.contains($0) }, "reason": "storage_limit"]
        json["metadata"] = metadata
        try DurableFile.replace(url, with: TranscriptAssembler.encode(json))
        Logger.files.info("StorageManager: marked \(url.lastPathComponent, privacy: .sensitive) — \(names.count, privacy: .public) audio file(s) removed")
    }

    /// `<id>-<n>.m4a` → `<id>`; `<id>.m4a` → `<id>`.
    static func stem(of name: String) -> String {
        let base = String(name.dropLast(".m4a".count))
        guard let dash = base.lastIndex(of: "-"), Int(base[base.index(after: dash)...]) != nil else { return base }
        return String(base[..<dash])
    }
}
