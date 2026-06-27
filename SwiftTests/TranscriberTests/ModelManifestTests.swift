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

@Suite struct ModelManifestServicePersistenceTests {
    private func makeService() -> (ModelManifestService, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-svc-\(UUID().uuidString)")
        return (ModelManifestService(manifestDir: dir), dir)
    }

    @Test func recordWritesManifestThatLoadsBack() async throws {
        let (svc, _) = makeService()

        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        try Data([0x01, 0x02]).write(to: cacheRoot.appendingPathComponent("a.bin"))

        // record() will try HF — accept whatever it returns since we treat HF failure as
        // a soft warning (empty commit sha is fine for this assertion).
        let manifest = try await svc.record(repo: "Test/example", cacheRoot: cacheRoot, sdkLabel: "test")
        #expect(manifest.repo == "Test/example")
        #expect(manifest.files.count == 1)

        let loaded = await svc.loadManifest(for: "Test/example")
        #expect(loaded == manifest)
    }

    @Test func verifyDetectsMissingAndCorruptFiles() async throws {
        let (svc, _) = makeService()

        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let goodFile = cacheRoot.appendingPathComponent("good.bin")
        let willCorrupt = cacheRoot.appendingPathComponent("flip.bin")
        let willDelete = cacheRoot.appendingPathComponent("gone.bin")
        try Data([0xAA]).write(to: goodFile)
        try Data([0xBB]).write(to: willCorrupt)
        try Data([0xCC]).write(to: willDelete)

        _ = try await svc.record(repo: "Test/example", cacheRoot: cacheRoot, sdkLabel: "test")

        // Mutate one file and remove another.
        try Data([0xCD, 0xEF]).write(to: willCorrupt)
        try FileManager.default.removeItem(at: willDelete)

        let result = await svc.verify(repo: "Test/example", cacheRoot: cacheRoot)
        // #44: verify() must report missing AND corrupt together, not short-circuit.
        #expect(result.manifestPresent)
        #expect(result.hasProblems)
        #expect(!result.isOK)
        #expect(result.missing.contains("gone.bin"))
        #expect(result.corrupt.contains("flip.bin"))
        // The intact file must appear in neither set.
        #expect(!result.missing.contains("good.bin"))
        #expect(!result.corrupt.contains("good.bin"))
    }

    @Test func verifyReturnsNoManifestWhenAbsent() async {
        let (svc, _) = makeService()
        let dummy = FileManager.default.temporaryDirectory
        let result = await svc.verify(repo: "Nope/none", cacheRoot: dummy)
        #expect(result == .noManifest)
        #expect(!result.manifestPresent)
        #expect(!result.hasProblems)
        #expect(!result.isOK)
    }

    @Test func verifyReturnsOKWhenAllFilesIntact() async throws {
        let (svc, _) = makeService()
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        try Data([0xAA, 0xBB]).write(to: cacheRoot.appendingPathComponent("a.bin"))

        _ = try await svc.record(repo: "Test/ok", cacheRoot: cacheRoot, sdkLabel: "test")
        let result = await svc.verify(repo: "Test/ok", cacheRoot: cacheRoot)
        #expect(result.isOK)
        #expect(result.missing.isEmpty)
        #expect(result.corrupt.isEmpty)
    }
}

// MARK: - #43: HFRepoResponse.lastModified parsing (mock URLSession)

/// Minimal URLProtocol stub: each test installs a `responder` that maps a request to a
/// canned (HTTPURLResponse, Data) pair. Lets us drive ModelManifestService's network path
/// without hitting Hugging Face.
final class ManifestMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = ManifestMockURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ManifestMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func ok200(_ request: URLRequest, _ json: String) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
    )!
    return (response, Data(json.utf8))
}

private func iso8601(_ s: String) -> Date? {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fmt.date(from: s)
}

@Suite struct HFRepoResponseParsingTests {
    @Test func decodesLastModifiedToExpectedDate() throws {
        let json = #"{"sha":"abc123","lastModified":"2026-05-01T12:00:00.000Z"}"#
        let decoded = try JSONDecoder().decode(
            ModelManifestService.HFRepoResponse.self, from: Data(json.utf8)
        )
        #expect(decoded.sha == "abc123")
        #expect(decoded.lastModified == "2026-05-01T12:00:00.000Z")

        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 1
        comps.hour = 12; comps.minute = 0; comps.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let expected = cal.date(from: comps)!
        #expect(iso8601(decoded.lastModified!) == expected)
    }

    @Test func missingLastModifiedDecodesToNil() throws {
        let json = #"{"sha":"deadbeef"}"#
        let decoded = try JSONDecoder().decode(
            ModelManifestService.HFRepoResponse.self, from: Data(json.utf8)
        )
        #expect(decoded.sha == "deadbeef")
        #expect(decoded.lastModified == nil)
    }

    @Test func malformedLastModifiedStringYieldsNilDate() throws {
        let json = #"{"sha":"abc","lastModified":"not-a-real-date"}"#
        let decoded = try JSONDecoder().decode(
            ModelManifestService.HFRepoResponse.self, from: Data(json.utf8)
        )
        // The string still decodes (it is a String?), but parsing it to a Date fails.
        #expect(decoded.lastModified == "not-a-real-date")
        #expect(iso8601(decoded.lastModified!) == nil)
    }
}

@Suite(.serialized) struct ModelManifestServiceNetworkTests {
    @Test func checkForUpdateParsesRemoteLastModifiedViaMockSession() async throws {
        defer { ManifestMockURLProtocol.responder = nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-net-\(UUID().uuidString)")
        let svc = ModelManifestService(manifestDir: dir, session: makeMockSession())
        defer { try? FileManager.default.removeItem(at: dir) }

        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        try Data([0x01]).write(to: cacheRoot.appendingPathComponent("a.bin"))

        // Baseline: record establishes a manifest with commit "AAA000".
        ManifestMockURLProtocol.responder = { req in
            ok200(req, #"{"sha":"AAA000","lastModified":"2026-01-01T00:00:00.000Z"}"#)
        }
        let recorded = try await svc.record(repo: "Test/repo", cacheRoot: cacheRoot, sdkLabel: "test")
        #expect(recorded.commitSha == "AAA000")

        // Remote has since moved to "BBB111" with a new lastModified.
        ManifestMockURLProtocol.responder = { req in
            ok200(req, #"{"sha":"BBB111","lastModified":"2026-05-01T12:00:00.000Z"}"#)
        }
        let status = await svc.checkForUpdate(repo: "Test/repo")
        guard case let .updateAvailable(local, remote, when) = status else {
            Issue.record("Expected .updateAvailable, got \(status)")
            return
        }
        #expect(local == "AAA000")
        #expect(remote == "BBB111")
        #expect(when == "2026-05-01T12:00:00.000Z")
        #expect(iso8601(when!) != nil)
    }
}
