import Foundation
import Testing
@testable import TranscriberCore

@Suite struct ModelManifestTests {
    @Test func manifestRoundTripsThroughJSON() throws {
        let original = ModelManifest(
            repo: "Acme/example-model",
            commitSha: "deadbeef",
            lastModifiedISO: "2026-05-01T00:00:00Z",
            downloadedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sdkLabel: "FluidAudio 0.14.4",
            files: [
                .init(relativePath: "Encoder.mlmodelc/weights.bin", size: 12345, sha256: "abc"),
                .init(relativePath: "vocab.json", size: 678, sha256: "def"),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ModelManifest.self, from: data)
        #expect(decoded == original)
    }

    @Test func manifestUsesSnakeCaseKeys() throws {
        let m = ModelManifest(
            repo: "x/y", commitSha: "s", lastModifiedISO: nil,
            downloadedAt: Date(timeIntervalSince1970: 0),
            sdkLabel: "x", files: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try String(data: encoder.encode(m), encoding: .utf8)!
        #expect(json.contains("\"commit_sha\""))
        #expect(json.contains("\"sdk_label\""))
        #expect(json.contains("\"downloaded_at\""))
    }
}

@Suite struct ModelManifestServiceHashingTests {
    @Test func sha256OfEmptyFileMatchesKnownDigest() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-empty-\(UUID().uuidString)")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sha = try ModelManifestService.sha256(of: tmp)
        // SHA-256 of empty input
        #expect(sha == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func sha256OfMultiChunkFileIsStable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-big-\(UUID().uuidString)")
        // ~3 MiB so we cross at least three 1 MiB chunks.
        let chunk = Data(repeating: 0x41, count: 1 << 20)
        try (chunk + chunk + chunk).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = try ModelManifestService.sha256(of: tmp)
        let b = try ModelManifestService.sha256(of: tmp)
        #expect(a == b)
        #expect(a.count == 64)  // hex digest length
    }
}

@Suite struct ModelManifestServiceWalkTests {
    @Test func walkProducesStableSortedEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sub = root.appendingPathComponent("Encoder.mlmodelc")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data([0x01]).write(to: sub.appendingPathComponent("weights.bin"))
        try Data([0x02, 0x03]).write(to: root.appendingPathComponent("vocab.json"))

        let entries = try ModelManifestService.hashAllFiles(under: root)
        #expect(entries.count == 2)
        // Sorted alphabetically by relative path.
        #expect(entries[0].relativePath == "Encoder.mlmodelc/weights.bin")
        #expect(entries[1].relativePath == "vocab.json")
        #expect(entries[0].size == 1)
        #expect(entries[1].size == 2)
        #expect(!entries[0].sha256.isEmpty)
    }

    @Test func walkSkipsDirectoryEntriesAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("real.bin")
        try Data([0xAA]).write(to: target)
        let link = root.appendingPathComponent("alias.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let entries = try ModelManifestService.hashAllFiles(under: root)
        // Symlink should not be hashed as a regular file.
        #expect(entries.count == 1)
        #expect(entries[0].relativePath == "real.bin")
    }
}
