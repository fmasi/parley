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

// MARK: - #349: the update check compares the entries Parley loads, not the commit

/// The real Parakeet repo's top-level entries at aed0274 (what this Mac has) and 7dd20fe (the
/// commit that added Encoder_v2.mlmodelc and rewrote config.json), trimmed.
private let treeAtAAA = #"""
[{"type":"directory","path":"Encoder.mlmodelc","oid":"ad3baf90"},
 {"type":"directory","path":"Decoder.mlmodelc","oid":"5e99a83f"},
 {"type":"directory","path":"JointDecisionv3.mlmodelc","oid":"f6d45f43"},
 {"type":"directory","path":"Preprocessor.mlmodelc","oid":"baff9992"},
 {"type":"file","path":"config.json","oid":"9e26dfee","size":2},
 {"type":"file","path":"parakeet_vocab.json","oid":"c684822e","size":151122}]
"""#
private let treeAtBBBAddsEncoderV2 = #"""
[{"type":"directory","path":"Encoder.mlmodelc","oid":"ad3baf90"},
 {"type":"directory","path":"Encoder_v2.mlmodelc","oid":"3b2b4a96"},
 {"type":"directory","path":"Decoder.mlmodelc","oid":"5e99a83f"},
 {"type":"directory","path":"JointDecisionv3.mlmodelc","oid":"f6d45f43"},
 {"type":"directory","path":"Preprocessor.mlmodelc","oid":"baff9992"},
 {"type":"file","path":"config.json","oid":"b6a1d442","size":475},
 {"type":"file","path":"parakeet_vocab.json","oid":"c684822e","size":151122}]
"""#
private let treeAtBBBChangesEncoder = treeAtAAA.replacingOccurrences(of: "ad3baf90", with: "0badf00d")

private let parakeetLoaded: Set<String> = [
    "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "Preprocessor.mlmodelc", "parakeet_vocab.json",
]

@Suite struct ModelTreeComparisonTests {
    private func tree(_ json: String) throws -> [String: String] {
        let entries = try JSONDecoder().decode([ModelManifestService.HFTreeEntry].self, from: Data(json.utf8))
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.oid) })
    }

    @Test func aNewFileAndAnUnloadedChangeAreNotAnUpdate() throws {
        let diff = ModelManifestService.compareTrees(
            local: try tree(treeAtAAA), remote: try tree(treeAtBBBAddsEncoderV2), loaded: parakeetLoaded
        )
        #expect(diff.changed.isEmpty)
        #expect(diff.added == ["Encoder_v2.mlmodelc"])
    }

    @Test func aChangedLoadedEntryIsAnUpdate() throws {
        let diff = ModelManifestService.compareTrees(
            local: try tree(treeAtAAA), remote: try tree(treeAtBBBChangesEncoder), loaded: parakeetLoaded
        )
        #expect(diff.changed == ["Encoder.mlmodelc"])
        #expect(diff.added.isEmpty)
    }

    @Test func aLoadedEntryRemovedUpstreamIsAnUpdate() {
        let diff = ModelManifestService.compareTrees(
            local: ["Encoder.mlmodelc": "a", "Decoder.mlmodelc": "b"],
            remote: ["Decoder.mlmodelc": "b"],
            loaded: ["Encoder.mlmodelc", "Decoder.mlmodelc"]
        )
        #expect(diff.changed == ["Encoder.mlmodelc"])
    }

    @Test func aLoadedEntryAbsentFromBothSidesIsUnchanged() {
        let diff = ModelManifestService.compareTrees(
            local: ["Decoder.mlmodelc": "b"], remote: ["Decoder.mlmodelc": "b", "README.md": "r"],
            loaded: ["Encoder.mlmodelc", "Decoder.mlmodelc"]
        )
        #expect(diff.changed.isEmpty)
        #expect(diff.added == ["README.md"])
    }

    @Test func parakeetLoadedEntriesAreTheInt8V3FilesAndTheVocabulary() {
        #expect(FluidAudioEngine.loadedModelEntries == parakeetLoaded)
    }
}

@Suite(.serialized) struct ModelManifestServiceNetworkTests {
    /// A service with a manifest recorded at commit AAA000, then `responder` answering by URL path.
    private func serviceRecordedAtAAA(
        then remoteHead: String, trees: [String: String], treeStatus: Int = 200
    ) async throws -> (ModelManifestService, [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-net-\(UUID().uuidString)")
        let svc = ModelManifestService(manifestDir: dir, session: makeMockSession())
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try Data([0x01]).write(to: cacheRoot.appendingPathComponent("a.bin"))

        ManifestMockURLProtocol.responder = { req in
            ok200(req, #"{"sha":"AAA000","lastModified":"2026-01-01T00:00:00.000Z"}"#)
        }
        let recorded = try await svc.record(repo: "Test/repo", cacheRoot: cacheRoot, sdkLabel: "test")
        #expect(recorded.commitSha == "AAA000")

        ManifestMockURLProtocol.responder = { req in
            let path = req.url!.path
            if let revision = path.components(separatedBy: "/tree/").dropFirst().first {
                guard treeStatus == 200 else {
                    let response = HTTPURLResponse(url: req.url!, statusCode: treeStatus, httpVersion: nil, headerFields: nil)!
                    return (response, Data())
                }
                return ok200(req, trees[revision] ?? "[]")
            }
            return ok200(req, #"{"sha":"\#(remoteHead)","lastModified":"2026-08-19T20:10:29.000Z"}"#)
        }
        return (svc, [dir, cacheRoot])
    }

    @Test func sameCommitIsUpToDate() async throws {
        defer { ManifestMockURLProtocol.responder = nil }
        let (svc, dirs) = try await serviceRecordedAtAAA(then: "AAA000", trees: [:])
        defer { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(await svc.checkForUpdate(repo: "Test/repo", loadedEntries: parakeetLoaded) == .upToDate(commitSha: "AAA000"))
    }

    @Test func aCommitThatOnlyAddsEncoderV2IsNotAnUpdate() async throws {
        defer { ManifestMockURLProtocol.responder = nil }
        let (svc, dirs) = try await serviceRecordedAtAAA(
            then: "BBB111", trees: ["AAA000": treeAtAAA, "BBB111": treeAtBBBAddsEncoderV2]
        )
        defer { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }
        let status = await svc.checkForUpdate(repo: "Test/repo", loadedEntries: parakeetLoaded)
        #expect(status == .loadedFilesUnchanged(
            localCommitSha: "AAA000", remoteCommitSha: "BBB111", addedEntries: ["Encoder_v2.mlmodelc"]
        ))
    }

    @Test func aCommitThatChangesALoadedFileIsAnUpdate() async throws {
        defer { ManifestMockURLProtocol.responder = nil }
        let (svc, dirs) = try await serviceRecordedAtAAA(
            then: "BBB111", trees: ["AAA000": treeAtAAA, "BBB111": treeAtBBBChangesEncoder]
        )
        defer { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }
        let status = await svc.checkForUpdate(repo: "Test/repo", loadedEntries: parakeetLoaded)
        #expect(status == .updateAvailable(
            localCommitSha: "AAA000", remoteCommitSha: "BBB111",
            remoteLastModifiedISO: "2026-08-19T20:10:29.000Z", changedEntries: ["Encoder.mlmodelc"]
        ))
    }

    @Test func aFailedTreeListingIsACheckFailureNotAVerdict() async throws {
        defer { ManifestMockURLProtocol.responder = nil }
        let (svc, dirs) = try await serviceRecordedAtAAA(then: "BBB111", trees: [:], treeStatus: 500)
        defer { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }
        let status = await svc.checkForUpdate(repo: "Test/repo", loadedEntries: parakeetLoaded)
        guard case .checkFailed = status else {
            Issue.record("Expected .checkFailed, got \(status)")
            return
        }
    }

    @Test func noManifestIsNoBaseline() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-net-\(UUID().uuidString)")
        let svc = ModelManifestService(manifestDir: dir, session: makeMockSession())
        #expect(await svc.checkForUpdate(repo: "Test/repo", loadedEntries: parakeetLoaded) == .noBaseline)
    }
}

@Suite struct ModelUpdateNoticeTests {
    private let everyStatus: [ManifestUpdateStatus] = [
        .upToDate(commitSha: "aed02740059"),
        .loadedFilesUnchanged(localCommitSha: "aed02740059", remoteCommitSha: "7dd20fe1234", addedEntries: ["Encoder_v2.mlmodelc"]),
        .loadedFilesUnchanged(localCommitSha: "aed02740059", remoteCommitSha: "7dd20fe1234", addedEntries: []),
        .updateAvailable(localCommitSha: "aed02740059", remoteCommitSha: "7dd20fe1234",
                         remoteLastModifiedISO: "2026-08-19T20:10:29.000Z", changedEntries: ["Encoder.mlmodelc"]),
        .noBaseline,
        .checkFailed(reason: "offline"),
    ]

    @Test func noMessagePointsAtSetupOrAManualCacheClear() {
        for status in everyStatus {
            let message = ModelUpdateNotice.message(for: status)
            #expect(!message.contains("Setup"), "\(status)")
            #expect(!message.localizedCaseInsensitiveContains("clear the model cache"), "\(status)")
        }
    }

    @Test func newFilesOnlyIsUpToDateAndNamesThem() {
        let message = ModelUpdateNotice.message(for: everyStatus[1])
        #expect(message.hasPrefix("Up to date (aed0274)."))
        #expect(message.contains("Encoder_v2.mlmodelc"))
        #expect(message.contains("Parley update"))
        #expect(!ModelUpdateNotice.offersRedownload(for: everyStatus[1]))
    }

    @Test func aChangedLoadedFileNamesItAndOffersTheRedownload() {
        let message = ModelUpdateNotice.message(for: everyStatus[3])
        #expect(message == "Update available: Encoder.mlmodelc changed on Hugging Face (aed0274 → 7dd20fe, 2026-08-19). Re-download the model to apply it.")
        #expect(ModelUpdateNotice.offersRedownload(for: everyStatus[3]))
    }

    @Test func aNewReadmeIsNotCalledSomethingAParleyUpdateWouldBringIn() {
        let message = ModelUpdateNotice.message(for: .loadedFilesUnchanged(
            localCommitSha: "aed02740059", remoteCommitSha: "7dd20fe1234", addedEntries: ["README.md", ".gitattributes"]
        ))
        #expect(message == "Up to date (aed0274). Hugging Face has a newer commit (7dd20fe), but none of the files Parley uses changed.")
    }

    @Test func onlyModelFilesAreNamedAsNew() {
        let message = ModelUpdateNotice.message(for: .loadedFilesUnchanged(
            localCommitSha: "aed02740059", remoteCommitSha: "7dd20fe1234",
            addedEntries: ["Encoder_v2.mlmodelc", "NOTES.md", "vocab_v4.json"]
        ))
        #expect(message.contains("Encoder_v2.mlmodelc and vocab_v4.json"))
        #expect(message.contains("bring them in"))
        #expect(!message.contains("NOTES.md"))
    }

    @Test func onlyAChangeOrAMissingBaselineOffersTheRedownload() {
        #expect(everyStatus.map(ModelUpdateNotice.offersRedownload(for:)) == [false, false, false, true, true, false])
    }
}

@Suite struct ModelRedownloadTests {
    private func makeCache() throws -> (parent: URL, cache: URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("redownload-\(UUID().uuidString)")
        let cache = parent.appendingPathComponent("parakeet-tdt-0.6b-v3")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: cache.appendingPathComponent("model.bin"))
        return (parent, cache)
    }

    private func contents(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func entries(_ parent: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).sorted()
    }

    @Test func aCompleteDownloadReplacesTheCache() async throws {
        let (parent, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: parent) }
        try await ModelRedownload.run(
            cacheDir: cache,
            download: { staged in
                #expect(staged.lastPathComponent == cache.lastPathComponent)
                #expect(staged.deletingLastPathComponent().deletingLastPathComponent().path == parent.path)
                try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
                try Data("new".utf8).write(to: staged.appendingPathComponent("model.bin"))
            },
            isComplete: { _ in true }
        )
        #expect(contents(cache.appendingPathComponent("model.bin")) == "new")
        #expect(entries(parent) == ["parakeet-tdt-0.6b-v3"])
    }

    @Test func aFailedDownloadLeavesTheCacheUntouched() async throws {
        let (parent, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: parent) }
        await #expect(throws: URLError.self) {
            try await ModelRedownload.run(
                cacheDir: cache,
                download: { staged in
                    try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
                    try Data("partial".utf8).write(to: staged.appendingPathComponent("model.bin"))
                    throw URLError(.networkConnectionLost)
                },
                isComplete: { _ in true }
            )
        }
        #expect(contents(cache.appendingPathComponent("model.bin")) == "old")
        #expect(entries(parent) == ["parakeet-tdt-0.6b-v3"])
    }

    @Test func anIncompleteDownloadLeavesTheCacheUntouched() async throws {
        let (parent, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: parent) }
        await #expect(throws: ModelRedownloadError.incomplete) {
            try await ModelRedownload.run(
                cacheDir: cache,
                download: { staged in try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true) },
                isComplete: { _ in false }
            )
        }
        #expect(contents(cache.appendingPathComponent("model.bin")) == "old")
        #expect(entries(parent) == ["parakeet-tdt-0.6b-v3"])
    }

    @Test func aFailureBeforeTheSwapSaysTheModelIsUnchanged() {
        let message = ModelUpdateNotice.redownloadFailed(URLError(.notConnectedToInternet), afterSwap: false)
        #expect(message.hasPrefix("Re-download failed: "))
        #expect(message.hasSuffix(" The current model is unchanged."))
        #expect(ModelUpdateNotice.redownloadFailed(ModelRedownloadError.incomplete, afterSwap: false)
            == "Re-download failed: The downloaded model is incomplete. The current model is unchanged.")
    }

    @Test func aFailedSwapOrAFailureAfterItNeverClaimsTheModelIsUnchanged() {
        #expect(ModelUpdateNotice.redownloadFailed(ModelRedownloadError.swapFailed("EPERM"), afterSwap: false)
            == "Re-download failed: Replacing the model failed (EPERM).")
        let afterSwap = ModelUpdateNotice.redownloadFailed(URLError(.networkConnectionLost), afterSwap: true)
        #expect(!afterSwap.contains("unchanged"))
    }

    @Test func onlyAFailedSwapLeavesTheCurrentModelInDoubt() {
        #expect(ModelRedownloadError.incomplete.keptCurrentModel)
        #expect(!ModelRedownloadError.swapFailed("EPERM").keptCurrentModel)
        #expect(ModelRedownloadError.swapFailed("EPERM").errorDescription == "Replacing the model failed (EPERM).")
    }

    @Test func aMissingCacheIsCreated() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("redownload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let cache = parent.appendingPathComponent("parakeet-tdt-0.6b-v3")
        try await ModelRedownload.run(
            cacheDir: cache,
            download: { staged in
                try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
                try Data("new".utf8).write(to: staged.appendingPathComponent("model.bin"))
            },
            isComplete: { _ in true }
        )
        #expect(contents(cache.appendingPathComponent("model.bin")) == "new")
    }

    @Test func aStagingFolderLeftByAnEarlierRunIsRemoved() async throws {
        let (parent, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: parent) }
        let leftover = parent.appendingPathComponent(".parley-redownload-stale/parakeet-tdt-0.6b-v3")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try await ModelRedownload.run(
            cacheDir: cache,
            download: { staged in
                try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
                try Data("new".utf8).write(to: staged.appendingPathComponent("model.bin"))
            },
            isComplete: { _ in true }
        )
        #expect(entries(parent) == ["parakeet-tdt-0.6b-v3"])
    }
}
