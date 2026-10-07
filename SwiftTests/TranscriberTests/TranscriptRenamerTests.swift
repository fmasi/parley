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

    /// The faithful cross-session #162 scenario: a FRESH process opens a transcript that already
    /// carries speaker_names from an earlier rename session. The pre-existing name must survive.
    @Test func renameMergesIntoSpeakerNamesAlreadyOnDisk() throws {
        let url = try writeTranscript(
            segments: [
                seg("Alice", "hello", start: 0, end: 2),
                seg("Remote Speaker 2", "hi there", start: 3, end: 5),
            ],
            metadata: ["speaker_names": ["Remote Speaker 1": "Alice"]]
        )

        #expect(TranscriptRenamer.applyRenames(["Remote Speaker 2": "Bob"], jsonPath: url))

        let json = try readJSON(url)
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

    /// With no audio_paths this exercises the text-only fallback's `prefix` cap only — the
    /// primary resolved-audio cap needs a real audio fixture and is not covered here.
    @Test func collectRespectsMaxSamplesInTextOnlyFallback() throws {
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

    /// Channel wiring: `isLocal` must come from the segment's `source`, never the display name —
    /// renaming a speaker must not change which channel of the stereo archive we read.
    @Test func collectWiresIsLocalFromSegmentSource() throws {
        let url = try writeTranscript(segments: [
            seg("Local Speaker 1", "me talking", start: 0, end: 2, source: "local"),
            seg("Remote Speaker 1", "them talking", start: 3, end: 5, source: "remote"),
        ])

        let collected = try TranscriptRenamer.collectSpeakerSamples(
            from: url, maxSamplesPerSpeaker: 1
        )

        #expect(collected.map(\.id) == ["Local Speaker 1", "Remote Speaker 1"])
        #expect(collected[0].samples.first?.isLocal == true)
        #expect(collected[1].samples.first?.isLocal == false)
    }

    /// Preserved edge: a speaker whose segments are all zero/negative duration cannot be ranked
    /// (`rank` filters `duration > 0`), so it yields an entry with an EMPTY samples array — the
    /// CLI drops it, the GUI lists it sample-less. Pinned so a refactor doesn't silently change it.
    @Test func collectYieldsEmptySamplesForZeroDurationSpeaker() throws {
        let url = try writeTranscript(segments: [
            seg("Remote Speaker 1", "degenerate", start: 5, end: 5),
            seg("Remote Speaker 1", "backwards", start: 4, end: 3),
            seg("Remote Speaker 2", "normal speech", start: 6, end: 8),
        ])

        let collected = try TranscriptRenamer.collectSpeakerSamples(
            from: url, maxSamplesPerSpeaker: 3
        )

        #expect(collected.map(\.id) == ["Remote Speaker 1", "Remote Speaker 2"])
        #expect(collected[0].samples.isEmpty)
        #expect(!collected[1].samples.isEmpty)
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

    /// #204: `collectSpeakerSamples` prefers `metadata.chunk_durations` over opening the chunk
    /// files to measure their real length.
    ///
    /// Proven with a deliberately WRONG cached duration: the segment at absolute [5, 6] would, at
    /// each chunk's REAL length (an empty file has none, so `durations(of:)` would report `nil`
    /// and drop this sample), resolve to nothing playable. The cached metadata below claims chunk
    /// 0 is 10s long, which places the same segment inside chunk 0 instead — so a resolved,
    /// playable sample here can only mean the cache was used, not a fallback file read.
    @Test func collectUsesCachedChunkDurationsOverReadingTheFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("renamer-cache-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Contents are irrelevant to this test — only existence is checked before a resolved
        // sample is accepted — so these are empty placeholder chunk files, not real audio.
        let chunk0 = dir.appendingPathComponent("call-0.wav")
        let chunk1 = dir.appendingPathComponent("call-1.wav")
        try Data().write(to: chunk0)
        try Data().write(to: chunk1)

        let url = try writeTranscript(
            segments: [seg("Remote Speaker 1", "hello", start: 5, end: 6)],
            metadata: [
                "audio_paths": [chunk0.path, chunk1.path],
                "chunk_durations": [10.0, 10.0],
            ]
        )

        let collected = try TranscriptRenamer.collectSpeakerSamples(from: url, maxSamplesPerSpeaker: 1)
        #expect(collected.count == 1)
        let sample = try #require(collected.first?.samples.first)
        #expect(sample.audioFile?.lastPathComponent == "call-0.wav")
        #expect(sample.start == 5.0)
        #expect(sample.end == 6.0)
    }

    /// The json-based overload exists so `RenameWindowController`/`RenameDialog` can read a
    /// transcript ONCE and get both speakers and channel names from it (#207 follow-up) — it
    /// must behave identically to the URL-based entry point for the same content.
    @Test func collectFromParsedJSONMatchesCollectFromURL() throws {
        let url = try writeTranscript(
            segments: [seg("Remote Speaker 1", "hello there", start: 0, end: 2)]
        )
        let fromURL = try TranscriptRenamer.collectSpeakerSamples(from: url, maxSamplesPerSpeaker: 1)
        let fromJSON = TranscriptRenamer.collectSpeakerSamples(json: try readJSON(url), maxSamplesPerSpeaker: 1)

        #expect(fromJSON.count == fromURL.count)
        #expect(fromJSON.map { $0.id } == fromURL.map { $0.id })
        #expect(fromJSON.first?.samples.first?.text == fromURL.first?.samples.first?.text)
    }

    /// Unlike the URL-based entry point (`collectThrowsOnNonTranscriptJSON` below), the json-based
    /// overload has no way to throw — a dict with no `segments` key degrades to `[]`, because its
    /// caller has already committed to treating the dict as a transcript by the time it gets here.
    @Test func collectFromParsedJSONWithNoSegmentsYieldsEmptyNotAThrow() {
        let collected = TranscriptRenamer.collectSpeakerSamples(json: ["foo": 1], maxSamplesPerSpeaker: 1)
        #expect(collected.isEmpty)
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

    // MARK: - Flagged segments (R7 review round 1, #245)

    /// Five local lines and two remote ones: every kind of flag on the mic channel, one on the other.
    private func flaggedTranscript(rediarized: [String]? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flags-rename-\(UUID().uuidString).json")
        var metadata: [String: Any] = [:]
        if let rediarized { metadata[TranscriptRediarizer.rediarizedChannelsKey] = rediarized }
        try JSONSerialization.data(withJSONObject: ["metadata": metadata, "segments": [
            ["start": 0.0, "end": 2.0, "text": "real words", "speaker": "Local Speaker 1", "source": "local"],
            ["start": 2.0, "end": 4.0, "text": "bleed of the other side", "speaker": "Local Speaker 1", "source": "local", "echo": true],
            ["start": 4.0, "end": 5.0, "text": "hum", "speaker": "Local Speaker 1", "source": "local", "filtered": true],
            ["start": 5.0, "end": 6.0, "text": "real words", "speaker": "Local Speaker 1", "source": "local", "duplicate": true],
            ["text": "words without a time", "speaker": "Local Speaker 1", "source": "local", "time_unknown": true],
            ["start": 6.0, "end": 8.0, "text": "other words", "speaker": "Remote Speaker 1", "source": "remote"],
            ["start": 8.0, "end": 9.0, "text": "other words", "speaker": "Remote Speaker 1", "source": "remote", "duplicate": true],
        ]]).write(to: url)
        return url
    }

    private func speakersAfterRenaming(_ url: URL) throws -> [String] {
        #expect(TranscriptRenamer.applyRenames(["Local Speaker 1": "Alex", "Remote Speaker 1": "Sam"], jsonPath: url))
        return try speakers(of: readJSON(url))
    }

    @Test func samplesSkipFlaggedSegments() throws {
        let url = try flaggedTranscript(); defer { try? FileManager.default.removeItem(at: url) }
        let speakers = try TranscriptRenamer.collectSpeakerSamples(from: url, maxSamplesPerSpeaker: 5)
        let texts = speakers.flatMap { $0.samples.map(\.text) }
        #expect(texts == ["real words", "other words"])
    }

    /// #245: on a channel that was never re-detected a flagged line's label is still the one the
    /// pipeline gave it, so a rename reaches it — the JSON must not show two labels for one person.
    @Test func aFlaggedSegmentOnANeverRedetectedChannelIsRenamed() throws {
        let url = try flaggedTranscript(); defer { try? FileManager.default.removeItem(at: url) }
        #expect(try speakersAfterRenaming(url) == ["Alex", "Alex", "Alex", "Alex", "Alex", "Sam", "Sam"])
    }

    /// After a re-detect of the mic channel a flagged line there keeps the label an EARLIER
    /// diarization gave it, and that label can now be somebody else's: the rename must not reach it.
    /// The other channel was not re-detected, so its flagged line is renamed.
    @Test func aFlaggedSegmentOnARedetectedChannelKeepsItsLabel() throws {
        let url = try flaggedTranscript(rediarized: ["local"]); defer { try? FileManager.default.removeItem(at: url) }
        #expect(try speakersAfterRenaming(url)
                == ["Alex", "Local Speaker 1", "Local Speaker 1", "Local Speaker 1", "Local Speaker 1", "Sam", "Sam"])
    }

    @Test func redetectingTheOtherChannelProtectsOnlyItsOwnFlaggedSegments() throws {
        let url = try flaggedTranscript(rediarized: ["remote"]); defer { try? FileManager.default.removeItem(at: url) }
        #expect(try speakersAfterRenaming(url) == ["Alex", "Alex", "Alex", "Alex", "Alex", "Sam", "Remote Speaker 1"])
    }

    @Test func bothChannelsRedetectedRenamesUnflaggedSegmentsOnly() throws {
        let url = try flaggedTranscript(rediarized: ["local", "remote"]); defer { try? FileManager.default.removeItem(at: url) }
        #expect(try speakersAfterRenaming(url)
                == ["Alex", "Local Speaker 1", "Local Speaker 1", "Local Speaker 1", "Local Speaker 1", "Sam", "Remote Speaker 1"])
    }

    /// A flagged line that does not say which channel it is on cannot be shown to be on one that was
    /// left alone: once any channel has been re-detected it keeps its label.
    @Test func aFlaggedSegmentWithNoSourceIsRenamedOnlyWhenNothingWasRedetected() throws {
        func renamed(rediarized: [String]?) throws -> [String] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("flags-nosource-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            var metadata: [String: Any] = [:]
            if let rediarized { metadata[TranscriptRediarizer.rediarizedChannelsKey] = rediarized }
            try JSONSerialization.data(withJSONObject: ["metadata": metadata, "segments": [
                ["start": 0.0, "end": 2.0, "text": "real words", "speaker": "Speaker 1"],
                ["start": 2.0, "end": 3.0, "text": "real words", "speaker": "Speaker 1", "duplicate": true],
            ]]).write(to: url)
            #expect(TranscriptRenamer.applyRenames(["Speaker 1": "Alex"], jsonPath: url))
            return try speakers(of: readJSON(url))
        }
        #expect(try renamed(rediarized: nil) == ["Alex", "Alex"])
        #expect(try renamed(rediarized: []) == ["Alex", "Alex"])
        #expect(try renamed(rediarized: ["remote"]) == ["Alex", "Speaker 1"])
    }

    /// Builds before `rediarized_channels` existed stamped only `speaker_count_<channel>` at a
    /// re-detect: a transcript re-detected by one of them is protected the same way.
    @Test func aChannelRedetectedByAnOlderBuildKeepsItsFlaggedLabels() throws {
        let url = try flaggedTranscript(); defer { try? FileManager.default.removeItem(at: url) }
        var json = try readJSON(url)
        json["metadata"] = ["speaker_count_local": 1]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(try speakersAfterRenaming(url)
                == ["Alex", "Local Speaker 1", "Local Speaker 1", "Local Speaker 1", "Local Speaker 1", "Sam", "Sam"])
    }

    /// A `rediarized_channels` that is not a list of strings is not read as "never re-detected".
    @Test func anUnreadableRedetectRecordProtectsEveryFlaggedSegment() throws {
        let url = try flaggedTranscript(); defer { try? FileManager.default.removeItem(at: url) }
        var json = try readJSON(url)
        json["metadata"] = [TranscriptRediarizer.rediarizedChannelsKey: "local"]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(try speakersAfterRenaming(url)
                == ["Alex", "Local Speaker 1", "Local Speaker 1", "Local Speaker 1", "Local Speaker 1", "Sam", "Remote Speaker 1"])
    }
}

/// #224 review: the storage limit marks older transcripts while a rename may be writing the same
/// file. Every transcript read-modify-write runs one at a time, so neither edit is lost.
@Suite(.serialized)
struct TranscriptWritesTests {
    @Test("a rename waits for a transcript write already in progress")
    func renameWaitsForTheLock() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.json")
        let doc: [String: Any] = ["metadata": [:] as [String: Any],
                                  "segments": [["start": 0.0, "end": 1.0, "text": "hi", "speaker": "A"]]]
        try JSONSerialization.data(withJSONObject: doc).write(to: url)

        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        // A mark's read-modify-write, paused between its read and its write.
        let holder = Thread {
            TranscriptWrites.exclusive {
                var json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
                held.signal()
                release.wait()
                json["metadata"] = ["audio_removed": ["files": ["x.m4a"]]]
                try? JSONSerialization.data(withJSONObject: json).write(to: url)
            }
        }
        holder.start()
        held.wait()
        let renamed = Task.detached { TranscriptRenamer.applyRenames(["A": "Ann"], jsonPath: url) }
        // Room for a rename that does not wait to write first — the mark would then overwrite it.
        // With the lock it cannot start, so this pause can only hide the bug, never fail a fix.
        try await Task.sleep(for: .milliseconds(300))
        release.signal()
        #expect(await renamed.value)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let metadata = json?["metadata"] as? [String: Any]
        #expect((metadata?["audio_removed"] as? [String: Any])?["files"] as? [String] == ["x.m4a"])
        #expect((json?["segments"] as? [[String: Any]])?.first?["speaker"] as? String == "Ann")
    }
}
