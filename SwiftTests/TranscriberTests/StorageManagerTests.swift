import Testing
import Foundation
@testable import TranscriberCore

struct StorageManagerTests {

    private static func createFakeM4a(at url: URL, sizeBytes: Int) throws {
        let data = Data(repeating: 0, count: sizeBytes)
        try data.write(to: url)
    }

    @Test func quotaInBytesCalculation() {
        let bytes = StorageManager.quotaBytes(hours: 15, bitrateKbps: 64)
        #expect(bytes == 15 * 64000 / 8 * 3600)
    }

    @Test func noCleanupWhenUnderQuota() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("small.m4a")
        try Self.createFakeM4a(at: file, sizeBytes: 1024)

        let deleted = try StorageManager.enforceQuota(
            in: dir, limitHours: 15, bitrateKbps: 64, protectedFile: nil
        )
        #expect(deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func deletesOldestFilesWhenOverQuota() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tenMB = 10_000_000
        let old = dir.appendingPathComponent("old.m4a")
        let mid = dir.appendingPathComponent("mid.m4a")
        let new = dir.appendingPathComponent("new.m4a")
        try Self.createFakeM4a(at: old, sizeBytes: tenMB)
        Thread.sleep(forTimeInterval: 0.05)
        try Self.createFakeM4a(at: mid, sizeBytes: tenMB)
        Thread.sleep(forTimeInterval: 0.05)
        try Self.createFakeM4a(at: new, sizeBytes: tenMB)

        let deleted = try StorageManager.enforceQuota(
            in: dir, limitHours: 1, bitrateKbps: 64, protectedFile: nil
        )

        #expect(!deleted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.path))
    }

    @Test func deletesOldestAcrossSubdirectories() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-test-\(UUID().uuidString)")
        let subA = dir.appendingPathComponent("2026-03-31")
        let subB = dir.appendingPathComponent("2026-04-01")
        try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tenMB = 10_000_000
        let oldFile = subA.appendingPathComponent("old-meeting.m4a")
        try Self.createFakeM4a(at: oldFile, sizeBytes: tenMB)
        Thread.sleep(forTimeInterval: 0.05)
        let newFile = subB.appendingPathComponent("new-meeting.m4a")
        try Self.createFakeM4a(at: newFile, sizeBytes: tenMB)

        // Quota for 1 hour at 64 kbps ≈ 28.8 MB — both files (20 MB) fit
        let deletedUnder = try StorageManager.enforceQuota(
            in: dir, limitHours: 1, bitrateKbps: 64, protectedFile: nil
        )
        #expect(deletedUnder.isEmpty)

        // Add a third file to push over a tighter quota
        Thread.sleep(forTimeInterval: 0.05)
        let extraFile = subB.appendingPathComponent("extra.m4a")
        try Self.createFakeM4a(at: extraFile, sizeBytes: tenMB)

        // 30 MB total, quota ~28.8 MB — oldest should be deleted
        let deleted = try StorageManager.enforceQuota(
            in: dir, limitHours: 1, bitrateKbps: 64, protectedFile: nil
        )
        #expect(!deleted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(FileManager.default.fileExists(atPath: newFile.path))
        #expect(FileManager.default.fileExists(atPath: extraFile.path))
    }

    @Test func neverDeletesProtectedFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fiveMB = 5_000_000
        let file = dir.appendingPathComponent("protected.m4a")
        try Self.createFakeM4a(at: file, sizeBytes: fiveMB)

        let deleted = try StorageManager.enforceQuota(
            in: dir, limitHours: 0, bitrateKbps: 64, protectedFile: file
        )

        #expect(deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func ignoresNonM4aFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonFile = dir.appendingPathComponent("transcript.json")
        try Data(repeating: 0, count: 50_000_000).write(to: jsonFile)

        let deleted = try StorageManager.enforceQuota(
            in: dir, limitHours: 1, bitrateKbps: 64, protectedFile: nil
        )
        #expect(deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: jsonFile.path))
    }

    @Test func currentUsageBytes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-test-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("2026-04-01")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Self.createFakeM4a(at: dir.appendingPathComponent("a.m4a"), sizeBytes: 1000)
        try Self.createFakeM4a(at: sub.appendingPathComponent("b.m4a"), sizeBytes: 2000)
        // Non-m4a should not be counted
        try Data(repeating: 0, count: 9999).write(to: sub.appendingPathComponent("c.json"))

        let usage = StorageManager.currentUsageBytes(in: dir)
        #expect(usage == 3000)
    }

    /// Round 8 item 2: protected files alone over the quota — nothing can be deleted, and the report
    /// says by how much, instead of passing in silence.
    @Test func aProtectedOverrunIsReported() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mine = dir.appendingPathComponent("m-0.m4a")
        try Self.createFakeM4a(at: mine, sizeBytes: 4096)
        let report = try StorageManager.enforceQuotaReport(in: dir, limitHours: 0, bitrateKbps: 64, protectedFiles: [mine])
        #expect(report.deleted.isEmpty && report.protectedOverrunBytes == 4096)
        #expect(FileManager.default.fileExists(atPath: mine.path))
        let under = try StorageManager.enforceQuotaReport(in: dir, limitHours: 1, bitrateKbps: 64, protectedFiles: [mine])
        #expect(under.protectedOverrunBytes == 0)
    }

    // MARK: - Another session's archives (#230)

    /// A day folder with one 4 KiB archive per name; returns the folder.
    private static func dayFolder(archives: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in archives { try createFakeM4a(at: dir.appendingPathComponent(name), sizeBytes: 4096) }
        return dir
    }

    private static func archivesLeft(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".m4a") }.sorted()
    }

    /// #230: two sessions share a day folder. The one with a `session.json` there is still being recorded, processed or
    /// awaiting salvage: a quota pass that does not name its archives (another session's pass) must not delete them — its
    /// chunks, registered or not, and its merged file. The finished session's archive stays deletable.
    @Test func anotherSessionStillInFlightKeepsItsArchives() throws {
        let dir = try Self.dayFolder(archives: ["a-0.m4a", "b-0.m4a", "b-7.m4a", "b.m4a"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "b", meetingStart: Date(), chunkIndices: [0])

        let report = try StorageManager.enforceQuotaReport(in: dir, limitHours: 0, bitrateKbps: 64, protectedFiles: [])

        #expect(report.deleted.map(\.lastPathComponent) == ["a-0.m4a"], "only the finished session's archive")
        #expect(try Self.archivesLeft(in: dir) == ["b-0.m4a", "b-7.m4a", "b.m4a"])
        #expect(report.protectedOverrunBytes == 3 * 4096, "what it would not delete is reported, never silent")
    }

    /// #230: a session whose `session.json` another recording moved aside (`session-<id>.json`, or
    /// `session-<id>.<uuid>.json` when that name was taken) is protected the same way.
    @Test func aSessionMovedAsideKeepsItsArchives() throws {
        let dir = try Self.dayFolder(archives: ["a-0.m4a", "b-0.m4a", "c-0.m4a", "d-0.m4a"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "b", meetingStart: Date(), chunkIndices: [0])
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "c", meetingStart: Date(), chunkIndices: [0])   // moves b aside
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("session-b.json").path))
        // d's state, in the form a second move-aside gives it.
        let d = dir.appendingPathComponent("session-d.\(UUID().uuidString).json")
        try Data(#"{"sessionId":"d"}"#.utf8).write(to: d)

        let report = try StorageManager.enforceQuotaReport(in: dir, limitHours: 0, bitrateKbps: 64, protectedFiles: [])

        #expect(report.deleted.map(\.lastPathComponent) == ["a-0.m4a"])
        #expect(try Self.archivesLeft(in: dir) == ["b-0.m4a", "c-0.m4a", "d-0.m4a"])
    }

    /// #230: one id can be the start of another (`a` and `a-2`: an id is a time plus a typed name). `a-2-0.m4a` is only ever
    /// `a-2`'s chunk and `a-0.m4a` only ever `a`'s; `a-2.m4a` is `a`'s chunk 2 OR `a-2`'s merged file — the name cannot say
    /// which, so it is kept while EITHER session has state.
    @Test(arguments: [
        (inFlight: "a-2", kept: ["a-2-0.m4a", "a-2-11.m4a", "a-2.m4a"], deleted: ["a-0.m4a", "a-1.m4a", "a.m4a", "ab-0.m4a"]),
        (inFlight: "a", kept: ["a-0.m4a", "a-1.m4a", "a-2.m4a", "a.m4a"], deleted: ["a-2-0.m4a", "a-2-11.m4a", "ab-0.m4a"]),
    ])
    func aSessionIdThatStartsAnotherIsNotMistakenForIt(inFlight: String, kept: [String], deleted: [String]) throws {
        let dir = try Self.dayFolder(archives: kept + deleted)
        defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: inFlight, meetingStart: Date(), chunkIndices: [0])

        let report = try StorageManager.enforceQuotaReport(in: dir, limitHours: 0, bitrateKbps: 64, protectedFiles: [])

        #expect(try Self.archivesLeft(in: dir) == kept.sorted())
        #expect(report.deleted.map(\.lastPathComponent).sorted() == deleted.sorted(), "the finished session's stay deletable")
    }

    /// #230: a session file whose id cannot be read says a session has state there, not which: every archive in THAT
    /// folder is kept. Other folders are judged on their own.
    @Test func anUnreadableSessionFileKeepsEveryArchiveInItsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-test-\(UUID().uuidString)")
        let unknown = root.appendingPathComponent("day-1"), finished = root.appendingPathComponent("day-2")
        defer { try? FileManager.default.removeItem(at: root) }
        for dir in [unknown, finished] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.createFakeM4a(at: dir.appendingPathComponent("a-0.m4a"), sizeBytes: 4096)
        }
        try Data("not a session".utf8).write(to: unknown.appendingPathComponent("session.json"))

        let report = try StorageManager.enforceQuotaReport(in: root, limitHours: 0, bitrateKbps: 64, protectedFiles: [])

        #expect(report.deleted.map(\.lastPathComponent) == ["a-0.m4a"])
        #expect(try Self.archivesLeft(in: unknown) == ["a-0.m4a"])
        #expect(try Self.archivesLeft(in: finished).isEmpty)
    }

    /// #230: the folder is read for session files only when a delete is about to happen — never under the quota, never for
    /// a file the caller protects — and once per folder, however many files it holds.
    @Test func sessionFilesAreReadOnlyBeforeADeleteAndOncePerFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-test-\(UUID().uuidString)")
        let days = ["day-1", "day-2"].map { root.appendingPathComponent($0) }
        defer { try? FileManager.default.removeItem(at: root) }
        var mine: [URL] = []
        for day in days {
            try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
            for name in ["a-0.m4a", "a-1.m4a", "a-2.m4a"] { try Self.createFakeM4a(at: day.appendingPathComponent(name), sizeBytes: 4096) }
            mine.append(day.appendingPathComponent("a-0.m4a"))
        }
        var asked: [String] = []
        let scan: (URL) -> Set<String>? = { asked.append($0.lastPathComponent); return [] }

        _ = try StorageManager.enforceQuotaReport(in: root, limitHours: 1, bitrateKbps: 64, protectedFiles: [], sessionsWithState: scan)
        #expect(asked.isEmpty, "under the quota: nothing to delete, nothing read")

        let all = days.flatMap { day in ["a-0.m4a", "a-1.m4a", "a-2.m4a"].map { day.appendingPathComponent($0) } }
        _ = try StorageManager.enforceQuotaReport(in: root, limitHours: 0, bitrateKbps: 64, protectedFiles: all, sessionsWithState: scan)
        #expect(asked.isEmpty, "every file is the caller's own: nothing to delete, nothing read")

        let report = try StorageManager.enforceQuotaReport(in: root, limitHours: 0, bitrateKbps: 64, protectedFiles: mine, sessionsWithState: scan)
        #expect(asked.sorted() == ["day-1", "day-2"], "once per folder, for four deletes")
        #expect(report.deleted.count == 4)
    }

    /// #230 (missing test): a pass already past its deadline deletes nothing — not even with nothing protected — and says
    /// it did not finish.
    @Test func aPassPastItsDeadlineDeletesNothing() throws {
        let dir = try Self.dayFolder(archives: ["a-0.m4a", "b-0.m4a"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = try StorageManager.enforceQuotaReport(in: dir, limitHours: 0, bitrateKbps: 64, protectedFiles: [],
                                                           deadline: SuspendingClock.now - .seconds(1))

        #expect(!report.finished && report.deleted.isEmpty && report.protectedOverrunBytes == 0)
        #expect(try Self.archivesLeft(in: dir) == ["a-0.m4a", "b-0.m4a"])
    }

    /// #230 (missing test): the pass a finalize runs. The session's own state file is gone by then (the record is written
    /// first), so its audio is kept by name and by list: the merged `<id>.m4a`, its chunk files, and every file the
    /// transcript lists. Another, finished session's archive goes.
    @Test func theFinalizePassSparesTheMergedFileAndTheListedChunks() throws {
        let dir = try Self.dayFolder(archives: ["s.m4a", "s-0.m4a", "s-1.m4a", "listed.m4a", "other-0.m4a"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let overrun = TranscriptionRunner.quota(in: dir, sessionId: "s", limitHours: 0, bitrateKbps: 64,
                                                protectedFiles: [dir.appendingPathComponent("listed.m4a")],
                                                deadline: SuspendingClock.now + .seconds(30))

        #expect(try Self.archivesLeft(in: dir) == ["listed.m4a", "s-0.m4a", "s-1.m4a", "s.m4a"])
        #expect(overrun == 4 * 4096)
    }
}

// MARK: - The whole recordings tree (#224)

/// A synthetic recordings tree in a temp folder: day folders, archives with set modification dates, transcripts.
private struct RecordingsTree {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("quota-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func day(_ name: String) throws -> URL {
        let d = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// An archive of `bytes` bytes, last modified `daysAgo` days ago (no sleeps: the order is set, not waited for).
    @discardableResult
    func archive(_ day: String, _ name: String, bytes: Int = 200_000, daysAgo: Double) throws -> URL {
        let url = try self.day(day).appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
        return url
    }
    /// A transcript listing `audio` (file names), as the assembler writes one.
    @discardableResult
    func transcript(_ day: String, _ name: String, audio: [String]) throws -> URL {
        let d = try self.day(day)
        let url = d.appendingPathComponent(name)
        let json: [String: Any] = [
            "metadata": ["audio_files": audio, "audio_paths": audio.map { d.appendingPathComponent($0).path }, "language": "en"],
            "segments": [["start": 0.0, "end": 1.0, "text": "synthetic words", "speaker": "Speaker 1"]],
        ]
        try TranscriptAssembler.write(json, to: url)
        return url
    }
    func exists(_ day: String, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(day).appendingPathComponent(name).path)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// The quota at 1 kbit/s for one hour: 450,000 bytes — room for two 200,000-byte archives, not three.
private let smallLimit = (hours: 1, kbps: 1)

private func json(_ url: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func removedMark(_ url: URL) throws -> [String: Any]? {
    (try json(url)["metadata"] as? [String: Any])?["audio_removed"] as? [String: Any]
}

@Suite struct StorageManagerTreeTests {

    /// #224: a pass after a recording weighs the WHOLE recordings tree — every day folder — when the folder it wrote into is
    /// a day folder of the configured root; anything else stays the folder alone.
    @Test func theScopeIsTheWholeTreeOnlyForADayFolderOfTheRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/parley-synthetic/rec")
        #expect(StorageManager.quotaScope(for: root.appendingPathComponent("2026-10-07"), recordingRoot: root.path) == .tree(root))
        #expect(StorageManager.quotaScope(for: root.appendingPathComponent("2026-10-07/"), recordingRoot: root.path + "/") == .tree(root))
        let elsewhere = URL(fileURLWithPath: "/tmp/parley-synthetic/other/2026-10-07")
        #expect(StorageManager.quotaScope(for: elsewhere, recordingRoot: root.path) == .folder(elsewhere), "a day folder of another root")
        let notADay = root.appendingPathComponent("imports")
        #expect(StorageManager.quotaScope(for: notADay, recordingRoot: root.path) == .folder(notADay))
        let deeper = root.appendingPathComponent("2026-10-07/sub")
        #expect(StorageManager.quotaScope(for: deeper, recordingRoot: root.path) == .folder(deeper))
    }

    /// #224: archives in OTHER day folders are deleted, oldest first, and the pass stops as soon as usage is within the
    /// limit — it deletes no more than needed. Before, the pass saw only one day folder and never deleted across days.
    @Test func theTreePassDeletesAcrossDaysOldestFirstAndStopsAtTheLimit() throws {
        let t = try RecordingsTree(); defer { t.remove() }
        try t.archive("2026-03-01", "090000-a-0.m4a", daysAgo: 200)
        try t.archive("2026-03-02", "090000-b-0.m4a", daysAgo: 199)
        try t.archive("2026-03-02", "100000-c.m4a", daysAgo: 198)
        try t.archive("2026-10-07", "101500-d-0.m4a", daysAgo: 0)   // 800,000 bytes against 450,000: two must go

        let report = try StorageManager.enforceQuotaReport(scope: .tree(t.root), limitHours: smallLimit.hours,
                                                           bitrateKbps: smallLimit.kbps, protectedFiles: [])

        #expect(report.deleted.map(\.lastPathComponent) == ["090000-a-0.m4a", "090000-b-0.m4a"], "oldest first, across days")
        #expect(t.exists("2026-03-02", "100000-c.m4a") && t.exists("2026-10-07", "101500-d-0.m4a"), "no more than needed")
        #expect(report.finished && report.protectedOverrunBytes == 0)
    }

    /// #224 with #230: never the current session's archives (named by the caller) and never an archive of a session that
    /// still has state in its folder, whatever day it is in. The next oldest finished archive goes instead.
    @Test func theTreePassNeverDeletesTheCurrentOrAnInFlightSession() throws {
        let t = try RecordingsTree(); defer { t.remove() }
        try t.archive("2026-03-01", "090000-busy-0.m4a", daysAgo: 300)   // the oldest, but its session is still in flight
        try RecoveryFixtures.writeSessionJSON(dir: try t.day("2026-03-01"), sessionId: "090000-busy", meetingStart: Date(), chunkIndices: [0])
        let mine = try t.archive("2026-10-07", "101500-mine-0.m4a", daysAgo: 250)   // old file date, but this session's
        try t.archive("2026-03-05", "090000-done-0.m4a", daysAgo: 100)
        try t.archive("2026-03-06", "090000-newer-0.m4a", daysAgo: 50)

        let report = try StorageManager.enforceQuotaReport(scope: .tree(t.root), limitHours: smallLimit.hours,
                                                           bitrateKbps: smallLimit.kbps, protectedFiles: [mine])

        #expect(report.deleted.map(\.lastPathComponent) == ["090000-done-0.m4a", "090000-newer-0.m4a"])
        #expect(t.exists("2026-03-01", "090000-busy-0.m4a"), "an in-flight session's audio is kept")
        #expect(t.exists("2026-10-07", "101500-mine-0.m4a"), "the current session's audio is kept")
    }

    /// #224: each transcript whose audio was removed is marked, with exactly its files — names only — and nothing else in
    /// it changes. A transcript whose audio stayed is not touched.
    @Test func theTranscriptsOfRemovedAudioAreMarkedWithTheirFiles() throws {
        let t = try RecordingsTree(); defer { t.remove() }
        try t.archive("2026-03-01", "090000-a-0.m4a", daysAgo: 200)
        try t.archive("2026-03-01", "090000-a-1.m4a", daysAgo: 199)
        try t.archive("2026-03-01", "100000-b.m4a", daysAgo: 1)
        let a = try t.transcript("2026-03-01", "090000-a.json", audio: ["090000-a-0.m4a", "090000-a-1.m4a"])
        let b = try t.transcript("2026-03-01", "100000-b.json", audio: ["100000-b.m4a"])
        let segmentsBefore = try #require(try json(a)["segments"] as? [[String: Any]])
        let bBefore = try Data(contentsOf: b)

        let report = try StorageManager.enforceQuotaReport(scope: .tree(t.root), limitHours: 0, bitrateKbps: 64,
                                                           protectedFiles: [t.root.appendingPathComponent("2026-03-01/100000-b.m4a")])

        #expect(report.deleted.count == 2)
        #expect(report.removedRecordings == ["2026-03-01/090000-a.json"], "one recording, however many of its files")
        let mark = try #require(try removedMark(a))
        #expect(mark["files"] as? [String] == ["090000-a-0.m4a", "090000-a-1.m4a"])
        #expect(mark["reason"] as? String == "storage_limit")
        #expect((mark["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } != nil, "an ISO 8601 time")
        let after = try json(a)
        #expect((after["segments"] as? [[String: Any]])?.count == segmentsBefore.count)
        #expect((after["segments"] as? [[String: Any]])?.first?["text"] as? String == "synthetic words", "segments unchanged")
        #expect((after["metadata"] as? [String: Any])?["audio_files"] as? [String] == ["090000-a-0.m4a", "090000-a-1.m4a"],
                "the listing stays the record of what there was")
        #expect(try Data(contentsOf: b) == bBefore, "a transcript whose audio stayed is not rewritten")
    }

    /// #224: a later pass adds to an earlier mark rather than replacing it.
    @Test func aLaterRemovalAddsToTheMark() throws {
        let t = try RecordingsTree(); defer { t.remove() }
        try t.archive("2026-03-01", "090000-a-0.m4a", daysAgo: 200)
        let keep = try t.archive("2026-03-01", "090000-a-1.m4a", daysAgo: 199)
        let a = try t.transcript("2026-03-01", "090000-a.json", audio: ["090000-a-0.m4a", "090000-a-1.m4a"])
        _ = try StorageManager.enforceQuotaReport(scope: .tree(t.root), limitHours: 0, bitrateKbps: 64, protectedFiles: [keep])
        _ = try StorageManager.enforceQuotaReport(scope: .tree(t.root), limitHours: 0, bitrateKbps: 64, protectedFiles: [])
        #expect(try removedMark(a)?["files"] as? [String] == ["090000-a-0.m4a", "090000-a-1.m4a"])
    }

    /// #224: an archive no transcript lists — or whose transcript cannot be read — is still deleted when it is the oldest;
    /// it counts as a recording of its own.
    @Test func aMissingOrUnreadableTranscriptDoesNotStopTheDeletion() throws {
        let t = try RecordingsTree(); defer { t.remove() }
        try t.archive("2026-03-01", "090000-lost-0.m4a", daysAgo: 200)
        try t.archive("2026-03-02", "090000-bad-0.m4a", daysAgo: 199)
        try Data("not json".utf8).write(to: try t.day("2026-03-02").appendingPathComponent("090000-bad.json"))

        let report = try StorageManager.enforceQuotaReport(scope: .tree(t.root), limitHours: 0, bitrateKbps: 64, protectedFiles: [])

        #expect(report.deleted.count == 2)
        #expect(report.removedRecordings == ["2026-03-01/090000-lost", "2026-03-02/090000-bad"])
        #expect(try String(contentsOf: t.root.appendingPathComponent("2026-03-02/090000-bad.json"), encoding: .utf8) == "not json",
                "a file that is not a transcript is never rewritten")
    }

    /// #224: only Parley's archives are candidates — an `.m4a` named by the session rule (`HHmmss[-…].m4a`) directly in a
    /// `yyyy-MM-dd` day folder. Another `.m4a` anywhere in the tree, a WAV, a transcript: never deleted.
    @Test func filesThatAreNotParleyArchivesAreNeverDeleted() throws {
        let t = try RecordingsTree(); defer { t.remove() }
        let strays = [("", "notes.m4a"), ("2026-03-01", "podcast.m4a"), ("imports", "090000-x-0.m4a"), ("2026-03-01/sub", "090000-y-0.m4a")]
        for (folder, name) in strays {
            let d = folder.isEmpty ? t.root : try t.day(folder)
            try Data(repeating: 1, count: 1000).write(to: d.appendingPathComponent(name))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: d.appendingPathComponent(name).path)
        }
        try Data(repeating: 1, count: 1000).write(to: try t.day("2026-03-01").appendingPathComponent("090000-z-0.wav"))
        try t.archive("2026-03-02", "090000-real-0.m4a", daysAgo: 1)

        let report = try StorageManager.enforceQuotaReport(scope: .tree(t.root), limitHours: 0, bitrateKbps: 64, protectedFiles: [])

        #expect(report.deleted.map(\.lastPathComponent) == ["090000-real-0.m4a"])
        for (folder, name) in strays {
            #expect(FileManager.default.fileExists(atPath: t.root.appendingPathComponent(folder).appendingPathComponent(name).path), "\(name)")
        }
        #expect(t.exists("2026-03-01", "090000-z-0.wav"))
        #expect(report.protectedOverrunBytes == 4 * 1000, "what it may not delete is counted and reported, never silent")
    }

    /// #224: a day folder that is a symbolic link is not followed — as the Settings usage scan does not — so nothing behind
    /// it is deleted.
    @Test func aSymlinkedDayFolderIsNotFollowed() throws {
        let t = try RecordingsTree(); defer { t.remove() }
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("quota-elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try Data(repeating: 1, count: 1000).write(to: elsewhere.appendingPathComponent("090000-far-0.m4a"))
        try FileManager.default.createSymbolicLink(at: t.root.appendingPathComponent("2026-03-01"), withDestinationURL: elsewhere)
        try t.archive("2026-03-02", "090000-near-0.m4a", daysAgo: 1)

        let report = try StorageManager.enforceQuotaReport(scope: .tree(t.root), limitHours: 0, bitrateKbps: 64, protectedFiles: [])

        #expect(report.deleted.map(\.lastPathComponent) == ["090000-near-0.m4a"])
        #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("090000-far-0.m4a").path))
    }

    /// #224 with L review 251: the deadline still bounds the walk of the whole tree — a spent one deletes nothing.
    @Test func theDeadlineStillBoundsTheTreeWalk() throws {
        let t = try RecordingsTree(); defer { t.remove() }
        try t.archive("2026-03-01", "090000-a-0.m4a", daysAgo: 2)
        try t.archive("2026-03-02", "090000-b-0.m4a", daysAgo: 1)

        let report = try StorageManager.enforceQuotaReport(scope: .tree(t.root), limitHours: 0, bitrateKbps: 64, protectedFiles: [],
                                                           deadline: SuspendingClock.now - .seconds(1))

        #expect(!report.finished && report.deleted.isEmpty && report.removedRecordings.isEmpty)
        #expect(t.exists("2026-03-01", "090000-a-0.m4a") && t.exists("2026-03-02", "090000-b-0.m4a"))
        // The walk itself stops when told, part-way through the tree — not only the deletes after it.
        var asked = 0
        #expect(StorageManager.treeArchives(in: t.root, stop: { asked += 1; return asked > 2 }) == nil, "stopped mid-walk")
        #expect(StorageManager.treeArchives(in: t.root, stop: { false })?.count == 2, "walked whole when not told to stop")
    }
}

// MARK: - #294: the first chunk, and whose audio keeps the folder over

/// #294 item 1: a recording's first `session.json` is written when its pipeline is set up — not when its first chunk is
/// saved — so another session's quota pass already sees it in flight while that first chunk is being archived.
@MainActor
@Suite struct QuotaFirstChunkTests {
    private final class NoRotationClient: ChunkRotationClient {
        func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
            throw CancellationError()
        }
    }

    @Test func aSessionIsInFlightFromItsStartBeforeItsFirstChunkIsArchived() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = TranscriptionRunner()
        try runner.setupChunkedPipeline(captureClient: NoRotationClient(), outputDirectory: dir, sessionBaseName: "110851-standup",
                                        config: .default)
        defer { runner.teardownChunkedPipeline() }
        let processor = try #require(runner.chunkProcessor)
        await processor.awaitAllProcessed()   // no chunk yet: only the state written at the start

        #expect(SessionState.sessionIdsWithState(in: dir) == ["110851-standup"])
        #expect(try #require(SessionState.read(directory: dir)).chunks.isEmpty)

        // Its first chunk's archive lands, older than another recording's finished archive; that recording's pass runs.
        for (name, age) in [("110851-standup-0.m4a", 0.0), ("093000-review-0.m4a", 1.0)] {
            let url = dir.appendingPathComponent(name)
            try Data(count: 4096).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: age)], ofItemAtPath: url.path)
        }
        let report = try StorageManager.enforceQuotaReport(in: dir, limitHours: 0, bitrateKbps: 64, protectedFiles: [])

        #expect(report.deleted.map(\.lastPathComponent) == ["093000-review-0.m4a"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("110851-standup-0.m4a").path),
                "the first chunk's archive — its only copy once the WAVs go — is kept")
    }
}

/// #294 item 2–3: the overrun names whose audio keeps the folder over the quota — this recording's, another one's still in
/// flight, or every archive of a folder a session file that cannot be read holds — never "this session's" for all of them.
@Suite struct QuotaOverrunWordingTests {
    private func folder(_ archives: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in archives { try Data(count: 4096).write(to: dir.appendingPathComponent(name)) }
        return dir
    }

    @Test func thisRecordingsOwnAudio() throws {
        let dir = try folder(["110851-standup-0.m4a"]); defer { try? FileManager.default.removeItem(at: dir) }
        let report = try StorageManager.enforceQuotaReport(in: dir, limitHours: 0, bitrateKbps: 64,
                                                           protectedFiles: [dir.appendingPathComponent("110851-standup-0.m4a")])
        #expect(report.kept == [.thisRecording])
        #expect(report.overrunDescription == "4096 bytes over the quota, kept by audio it may not delete: this recording’s own")
    }

    @Test func anotherRecordingStillInFlight() throws {
        let dir = try folder(["093000-review-0.m4a"]); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "093000-review", meetingStart: Date(), chunkIndices: [0])
        let report = try StorageManager.enforceQuotaReport(in: dir, limitHours: 0, bitrateKbps: 64, protectedFiles: [])
        #expect(report.kept == [.anotherRecording])
        #expect(report.overrunDescription
                == "4096 bytes over the quota, kept by audio it may not delete: another recording’s, still being recorded or processed")
    }

    /// Item 3: a stray `session-*.json` whose recording cannot be read keeps every archive in its folder — and says so.
    @Test func aSessionFileThatCannotBeRead() throws {
        let dir = try folder(["093000-review-0.m4a"]); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("session-notes.json"))
        let report = try StorageManager.enforceQuotaReport(in: dir, limitHours: 0, bitrateKbps: 64, protectedFiles: [])
        #expect(report.deleted.isEmpty, "unchanged: the folder is still held")
        #expect(report.kept == [.unreadableSessionFile])
        #expect(report.overrunDescription
                == "4096 bytes over the quota, kept by audio it may not delete: every archive in a folder whose session state Parley cannot read")
    }

    @Test func severalReasonsAreAllNamedInAFixedOrder() throws {
        let dir = try folder(["093000-review-0.m4a", "110851-standup-0.m4a"]); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "093000-review", meetingStart: Date(), chunkIndices: [0])
        let report = try StorageManager.enforceQuotaReport(in: dir, limitHours: 0, bitrateKbps: 64,
                                                           protectedFiles: [dir.appendingPathComponent("110851-standup-0.m4a")])
        #expect(report.overrunDescription == "8192 bytes over the quota, kept by audio it may not delete: this recording’s own; "
                + "another recording’s, still being recorded or processed")
    }

    @Test func filesThatAreNotParleysArchives() throws {
        let t = try RecordingsTree(); defer { t.remove() }
        try Data(count: 1000).write(to: t.root.appendingPathComponent("notes.m4a"))
        let report = try StorageManager.enforceQuotaReport(scope: .tree(t.root), limitHours: 0, bitrateKbps: 64, protectedFiles: [])
        #expect(report.kept == [.notParleyArchive])
        #expect(report.overrunDescription == "1000 bytes over the quota, kept by audio it may not delete: files that are not Parley recordings")
    }

    @Test func nothingIsKeptUnderTheQuota() throws {
        let dir = try folder(["093000-review-0.m4a"]); defer { try? FileManager.default.removeItem(at: dir) }
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "093000-review", meetingStart: Date(), chunkIndices: [0])
        let report = try StorageManager.enforceQuotaReport(in: dir, limitHours: 1, bitrateKbps: 64, protectedFiles: [])
        #expect(report.kept.isEmpty && report.overrunDescription == nil)
    }
}
