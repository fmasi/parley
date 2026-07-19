import Testing
import Foundation
@testable import TranscriberCore

struct SummaryDisclosureTests {

    // MARK: - classification / no-leak

    @Test func airgappedDefaultTestifiesNoDisclosure() {
        let d = SummaryDisclosure.airgapped
        #expect(d.summaryGenerated == false)
        #expect(d.transcriptTransmitted == false)
        #expect(d.summaryEndpoint == nil)
        let dict = d.asMetadataDictionary()
        #expect(dict["summary_generated"] as? Bool == false)
        #expect(dict["transcript_transmitted"] as? Bool == false)
        #expect(dict["summary_endpoint"] == nil)
    }

    @Test func localhostSummaryIsOnDeviceNotTransmitted() {
        let d = SummaryDisclosure.generated(endpoint: "http://localhost:1234/api/v1/chat")
        #expect(d.summaryGenerated == true)
        #expect(d.transcriptTransmitted == false)
        #expect(d.summaryEndpoint?.contains("local") == true)
    }

    @Test func loopbackIPIsOnDevice() {
        #expect(SummaryDisclosure.generated(endpoint: "http://127.0.0.1:1234/v1").transcriptTransmitted == false)
    }

    // The remote label must carry the HOST ONLY — never the path, query, or any embedded token.
    @Test func remoteSummaryRecordsHostOnlyNeverTheSecret() {
        let d = SummaryDisclosure.generated(endpoint: "https://api.openai.com/v1/chat/completions?key=sk-SUPERSECRET")
        #expect(d.summaryGenerated == true)
        #expect(d.transcriptTransmitted == true)
        let label = d.summaryEndpoint ?? ""
        #expect(label.contains("api.openai.com"))
        #expect(!label.contains("sk-SUPERSECRET"))   // no credential
        #expect(!label.contains("/v1/"))             // no path
        #expect(!label.contains("?"))                // no query
    }

    @Test func unparsableEndpointClassifiesRemoteUnknownWithoutEchoing() {
        let d = SummaryDisclosure.generated(endpoint: "!!not a url with token sk-XYZ!!")
        #expect(d.transcriptTransmitted == true)
        #expect(d.summaryEndpoint == "remote (unknown)")
        #expect(!(d.summaryEndpoint ?? "").contains("sk-XYZ"))
    }

    // MARK: - stamp round-trip (the wiring)

    @Test func stampDisclosureRewritesMetadataInPlacePreservingOtherKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("m.json")

        // A transcript that starts airgapped, with an unrelated metadata key to preserve.
        let initial: [String: Any] = [
            "segments": [],
            "metadata": [
                "session_name": "standup",
                "disclosure": SummaryDisclosure.airgapped.asMetadataDictionary(),
            ],
        ]
        try JSONSerialization.data(withJSONObject: initial).write(to: path)

        try MeetingSummarizer.stampDisclosure(.generated(endpoint: "https://api.openai.com/v1"), into: path)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        let meta = json["metadata"] as! [String: Any]
        #expect(meta["session_name"] as? String == "standup")   // preserved
        let disc = meta["disclosure"] as! [String: Any]
        #expect(disc["summary_generated"] as? Bool == true)
        #expect(disc["transcript_transmitted"] as? Bool == true)
        #expect((disc["summary_endpoint"] as? String)?.contains("api.openai.com") == true)
    }
}
