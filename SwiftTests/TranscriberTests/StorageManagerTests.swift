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
