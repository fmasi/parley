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
