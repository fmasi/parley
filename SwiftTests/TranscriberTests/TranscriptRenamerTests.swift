import Testing
import Foundation
@testable import TranscriberCore

/// TranscriptRenamer: the shared speaker-rename logic behind both the CLI rename and the GUI
/// rename dialog. Covers segment remapping, the #162 merge semantics of
/// `metadata.speaker_names` (a second rename must not drop the first rename's names), and
/// speaker-sample collection.
struct TranscriptRenamerTests {

    // MARK: - Helpers

    private func seg(
        _ speaker: String, _ text: String,
        start: Double, end: Double, source: String = "remote"
    ) -> [String: Any] {
        ["speaker": speaker, "text": text, "start": start, "end": end, "source": source]
    }

    private func writeTranscript(
        segments: [[String: Any]],
        metadata: [String: Any]? = nil
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("renamer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var json: [String: Any] = ["segments": segments]
        if let metadata { json["metadata"] = metadata }
        let url = dir.appendingPathComponent("transcript.json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func speakers(of json: [String: Any]) throws -> [String] {
        let segments = try #require(json["segments"] as? [[String: Any]])
        return segments.compactMap { $0["speaker"] as? String }
    }

    private func speakerNames(of json: [String: Any]) -> [String: String]? {
        (json["metadata"] as? [String: Any])?["speaker_names"] as? [String: String]
    }

    // MARK: - applyRenames: remapping

    @Test func applyRenamesRemapsOnlyMappedSpeakers() throws {
        let url = try writeTranscript(segments: [
            seg("Remote Speaker 1", "hello", start: 0, end: 2),
            seg("Remote Speaker 2", "hi there", start: 3, end: 5),
            seg("Remote Speaker 1", "how are you", start: 6, end: 8),
        ])

        #expect(TranscriptRenamer.applyRenames(["Remote Speaker 1": "Alice"], jsonPath: url))

        let json = try readJSON(url)
        #expect(try speakers(of: json) == ["Alice", "Remote Speaker 2", "Alice"])
        #expect(speakerNames(of: json) == ["Remote Speaker 1": "Alice"])
    }

    @Test func applyRenamesPreservesSegmentTextAndOtherMetadata() throws {
        let url = try writeTranscript(
            segments: [seg("Remote Speaker 1", "hello", start: 0, end: 2)],
            metadata: ["output_format": "txt", "audio_paths": ["/tmp/a.m4a"]]
        )

        #expect(TranscriptRenamer.applyRenames(["Remote Speaker 1": "Alice"], jsonPath: url))

        let json = try readJSON(url)
        let metadata = try #require(json["metadata"] as? [String: Any])
        #expect(metadata["output_format"] as? String == "txt")
        #expect(metadata["audio_paths"] as? [String] == ["/tmp/a.m4a"])
        let segments = try #require(json["segments"] as? [[String: Any]])
        #expect(segments.first?["text"] as? String == "hello")
    }

    @Test func applyRenamesFailsOnMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("renamer-missing-\(UUID().uuidString).json")
        #expect(!TranscriptRenamer.applyRenames(["A": "B"], jsonPath: url))
    }

    // MARK: - applyRenames: #162 merge semantics

    /// The CLI path used to overwrite `metadata.speaker_names` wholesale with the current
    /// session's mapping, dropping every name applied in a previous rename (#162). A second
    /// rename must MERGE.
    @Test func secondRenameMergesIntoExistingSpeakerNames() throws {
        let url = try writeTranscript(segments: [
            seg("Remote Speaker 1", "hello", start: 0, end: 2),
            seg("Remote Speaker 2", "hi there", start: 3, end: 5),
        ])

        #expect(TranscriptRenamer.applyRenames(["Remote Speaker 1": "Alice"], jsonPath: url))
        #expect(TranscriptRenamer.applyRenames(["Remote Speaker 2": "Bob"], jsonPath: url))

        let json = try readJSON(url)
        #expect(try speakers(of: json) == ["Alice", "Bob"])
        #expect(speakerNames(of: json) == [
            "Remote Speaker 1": "Alice",
            "Remote Speaker 2": "Bob",
        ])
    }

    @Test func identityRenamesAreNotRecorded() throws {
        let url = try writeTranscript(segments: [
            seg("Remote Speaker 1", "hello", start: 0, end: 2),
            seg("Remote Speaker 2", "hi there", start: 3, end: 5),
        ])

        #expect(TranscriptRenamer.applyRenames(
            ["Remote Speaker 1": "Remote Speaker 1", "Remote Speaker 2": "Bob"], jsonPath: url
        ))

        let json = try readJSON(url)
        #expect(try speakers(of: json) == ["Remote Speaker 1", "Bob"])
        #expect(speakerNames(of: json) == ["Remote Speaker 2": "Bob"])
    }

    @Test func allIdentityMappingLeavesMetadataUntouched() throws {
        let url = try writeTranscript(segments: [
            seg("Remote Speaker 1", "hello", start: 0, end: 2)
        ])

        #expect(TranscriptRenamer.applyRenames(
            ["Remote Speaker 1": "Remote Speaker 1"], jsonPath: url
        ))

        let json = try readJSON(url)
        #expect(json["metadata"] == nil)
    }

    // MARK: - collectSpeakerSamples

    @Test func collectOrdersSpeakersByFirstAppearanceWithTextOnlyFallback() throws {
        // No audio_paths: the layout is unavailable, so every sample must fall back to
        // text-only (audioFile nil) rather than being dropped.
        let url = try writeTranscript(segments: [
            seg("Remote Speaker 1", "short", start: 0, end: 1),
            seg("Remote Speaker 2", "other voice", start: 2, end: 4),
            seg("Remote Speaker 1", "this is the much longer clean sample", start: 5, end: 12),
        ])

        let collected = try TranscriptRenamer.collectSpeakerSamples(
            from: url, maxSamplesPerSpeaker: 3
        )

        #expect(collected.map(\.id) == ["Remote Speaker 1", "Remote Speaker 2"])
        #expect(collected.allSatisfy { !$0.samples.isEmpty })
        #expect(collected.allSatisfy { $0.samples.allSatisfy { $0.audioFile == nil } })
        // Best-first: the longer isolated segment ranks above the short one.
        #expect(collected[0].samples.first?.text == "this is the much longer clean sample")
    }

    @Test func collectRespectsMaxSamplesPerSpeaker() throws {
        let url = try writeTranscript(segments: [
            seg("Remote Speaker 1", "one", start: 0, end: 1),
            seg("Remote Speaker 1", "two", start: 2, end: 3),
            seg("Remote Speaker 1", "three", start: 4, end: 5),
        ])

        let collected = try TranscriptRenamer.collectSpeakerSamples(
            from: url, maxSamplesPerSpeaker: 1
        )

        #expect(collected.count == 1)
        #expect(collected[0].samples.count == 1)
    }

    @Test func collectFiltersSpeakersBelowMinSegments() throws {
        var segments: [[String: Any]] = []
        for i in 0..<5 {
            segments.append(seg("Remote Speaker 1", "talkative \(i)", start: Double(i * 4), end: Double(i * 4 + 2)))
        }
        segments.append(seg("Remote Speaker 2", "noise blip", start: 30, end: 31))

        let collected = try TranscriptRenamer.collectSpeakerSamples(
            from: url(of: segments), maxSamplesPerSpeaker: 3, minSegmentsPerSpeaker: 5
        )

        #expect(collected.map(\.id) == ["Remote Speaker 1"])
    }

    @Test func collectFallsBackToUnfilteredWhenAllSpeakersAreBelowMinSegments() throws {
        let segments = [
            seg("Remote Speaker 1", "brief", start: 0, end: 1),
            seg("Remote Speaker 2", "also brief", start: 2, end: 3),
        ]

        let collected = try TranscriptRenamer.collectSpeakerSamples(
            from: url(of: segments), maxSamplesPerSpeaker: 3, minSegmentsPerSpeaker: 5
        )

        #expect(collected.map(\.id) == ["Remote Speaker 1", "Remote Speaker 2"])
    }

    private func url(of segments: [[String: Any]]) throws -> URL {
        try writeTranscript(segments: segments)
    }

    @Test func collectThrowsOnMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("renamer-missing-\(UUID().uuidString).json")
        #expect(throws: TranscriptRenamer.RenameError.cannotRead) {
            try TranscriptRenamer.collectSpeakerSamples(from: url, maxSamplesPerSpeaker: 1)
        }
    }

    @Test func collectThrowsOnNonTranscriptJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("renamer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("not-a-transcript.json")
        try Data("{\"foo\": 1}".utf8).write(to: url)

        #expect(throws: TranscriptRenamer.RenameError.invalidJSON) {
            try TranscriptRenamer.collectSpeakerSamples(from: url, maxSamplesPerSpeaker: 1)
        }
    }
}
