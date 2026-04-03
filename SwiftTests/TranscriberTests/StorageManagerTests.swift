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
        #expect(deleted.contains(old))
        #expect(FileManager.default.fileExists(atPath: new.path))
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
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Self.createFakeM4a(at: dir.appendingPathComponent("a.m4a"), sizeBytes: 1000)
        try Self.createFakeM4a(at: dir.appendingPathComponent("b.m4a"), sizeBytes: 2000)
        try Data(repeating: 0, count: 9999).write(to: dir.appendingPathComponent("c.json"))

        let usage = StorageManager.currentUsageBytes(in: dir)
        #expect(usage == 3000)
    }
}
