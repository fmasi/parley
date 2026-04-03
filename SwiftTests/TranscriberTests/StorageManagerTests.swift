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
}
