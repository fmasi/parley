import Foundation
import Testing
@testable import TranscriberCore

/// #224: the storage limit applies to the whole recordings tree, and the user is told when it removed older audio.
/// Every folder here is a synthetic temp tree — never the configured recordings folder.
@MainActor
@Suite struct StorageQuotaNoticeTests {

    private func tree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quota-notice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func dayFolder(_ root: URL, _ name: String) throws -> URL {
        let d = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// An older recording in `day`: its archive, last modified long ago, and its transcript listing it.
    private func olderRecording(_ root: URL, day: String, id: String) throws -> (archive: URL, transcript: URL) {
        let d = try dayFolder(root, day)
        let archive = d.appendingPathComponent("\(id)-0.m4a")
        try Data(repeating: 1, count: 4096).write(to: archive)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 86_400)], ofItemAtPath: archive.path)
        let transcript = d.appendingPathComponent("\(id).json")
        try TranscriptAssembler.write(["metadata": ["audio_files": ["\(id)-0.m4a"]],
                                       "segments": [["start": 0.0, "end": 1.0, "text": "synthetic", "speaker": "Speaker 1"]]],
                                      to: transcript)
        return (archive, transcript)
    }

    private func mark(_ url: URL) throws -> [String: Any]? {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return (json["metadata"] as? [String: Any])?["audio_removed"] as? [String: Any]
    }

    // MARK: - The notice's line

    /// The line names the count, and is there exactly when something was removed.
    @Test func theCompletionLineNamesTheCountOnlyWhenSomethingWasRemoved() {
        let plain = CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: 0, problemChunkCount: 0, segmentCount: 40)
        #expect(plain == "m.json")
        #expect(CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: 0, problemChunkCount: 0, segmentCount: 40,
                                                    removedRecordings: 0) == "m.json")
        #expect(CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: 0, problemChunkCount: 0, segmentCount: 40,
                                                    removedRecordings: 3)
                == "m.json\nRemoved the audio of 3 older recordings to stay within the storage limit; transcripts are kept.")
        #expect(CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: 0, problemChunkCount: 0, segmentCount: 40,
                                                    removedRecordings: 1)
                == "m.json\nRemoved the audio of 1 older recording to stay within the storage limit; transcripts are kept.")
        // Said even when the transcript itself could not be re-read.
        #expect(CaptureQualityNotice.completionBody(fileName: "m.json", anomalyCount: CaptureQualityNotice.unreadable, problemChunkCount: 0,
                                                    segmentCount: 40, removedRecordings: 2)
                .hasSuffix("\nRemoved the audio of 2 older recordings to stay within the storage limit; transcripts are kept."))
    }

    // MARK: - Finalize: the whole tree

    /// #224: a recording's finalize, in a day folder of the configured root, removes an OLDER DAY's audio (the pass used to
    /// see only its own day folder), marks that day's transcript, keeps its own audio, and hands the count to the notice.
    @Test func aFinalizeRemovesAnOlderDaysAudioAndReportsIt() async throws {
        let root = try tree(); defer { try? FileManager.default.removeItem(at: root) }
        let older = try olderRecording(root, day: "2026-03-01", id: "090000-old")
        let today = try dayFolder(root, "2026-10-07")
        try RecoveryFixtures.writeSessionJSON(dir: today, sessionId: "101500-f", meetingStart: Date(), chunkIndices: [0])
        try RecoveryFixtures.writeFakeWav(at: today.appendingPathComponent("101500-f-0.m4a"), seconds: 1)
        let state = try #require(SessionState.read(directory: today, sessionId: "101500-f"))
        var config = Config.default
        config.recordingDirectory = root.path   // never the real recordings folder
        config.audioArchiveLimitHours = 0

        let runner = TranscriptionRunner()
        runner.folderReads = FolderReads(label: "quota-notice-\(UUID().uuidString)")
        let result = try await runner.finalize(sessionState: state, outputDirectory: today, config: config)
        let removed = await result.quotaPass?.removedRecordings(within: 30)

        #expect(removed == ["2026-03-01/090000-old.json"])
        #expect(!FileManager.default.fileExists(atPath: older.archive.path), "the older day's audio is removed")
        #expect(FileManager.default.fileExists(atPath: older.transcript.path), "its transcript is kept")
        #expect(try mark(older.transcript)?["files"] as? [String] == ["090000-old-0.m4a"])
        #expect(FileManager.default.fileExists(atPath: today.appendingPathComponent("101500-f-0.m4a").path), "never its own audio")
    }

    // MARK: - Per chunk: still the day folder, now counted and marked

    /// #224: a chunk's pass (still scoped to the day folder) that removes another recording's audio marks its transcript and
    /// records the recording in the session, so the completion notice can name it.
    @Test func aChunksPassRecordsWhatItRemovedForTheNotice() async throws {
        let root = try tree(); defer { try? FileManager.default.removeItem(at: root) }
        let older = try olderRecording(root, day: "2026-10-07", id: "090000-old")
        let today = root.appendingPathComponent("2026-10-07")
        try RecoveryFixtures.writeFakeWav(at: today.appendingPathComponent("101500-m-0.wav"), seconds: 1)
        var config = Config.default
        config.recordingDirectory = root.path
        config.audioArchiveLimitHours = 0
        let processor = ChunkProcessor(config: config, outputDirectory: today,
                                       sessionState: SessionState(sessionId: "101500-m", meetingStart: Date(timeIntervalSince1970: 0),
                                                                  engine: "fluidAudio", chunkDurationMinutes: 10, chunks: []),
                                       transcriber: FakeEngine(), diarizer: FakeDiarizer())

        await processor.processLastChunk(ChunkRotator.FinalizedChunk(
            index: 0, systemPath: today.appendingPathComponent("101500-m-0.wav").path,
            micPath: today.appendingPathComponent("101500-m-0_mic.wav").path, startTime: Date(timeIntervalSince1970: 0)))
        let state = await processor.getSessionState()

        #expect(state.quotaRemovedRecordings == ["2026-10-07/090000-old.json"])
        #expect(!FileManager.default.fileExists(atPath: older.archive.path))
        #expect(try mark(older.transcript)?["files"] as? [String] == ["090000-old-0.m4a"])
        #expect(FileManager.default.fileExists(atPath: today.appendingPathComponent("101500-m-0.m4a").path), "its own chunk is kept")
    }

    // MARK: - The completion notice

    private func plainTranscript(_ h: Harness) throws -> URL {
        let url = h.tmp.appendingPathComponent("101500-done.json")
        try JSONSerialization.data(withJSONObject: [
            "metadata": ["capture_provenance": ["quality_anomaly_count": 0]],
            "segments": [["start": 0.0, "end": 1.0, "text": "x", "speaker": "Speaker 1", "source": "remote"]],
        ]).write(to: url)
        return url
    }

    /// The recording's own per-chunk removals and its finalize's are counted together, once per recording.
    @Test func theCompletionNoticeSaysHowManyOlderRecordingsLostTheirAudio() async throws {
        let h = try Harness()
        let url = try plainTranscript(h)
        let pass = QuotaOutcome()
        pass.deliver(removedRecordings: ["2026-03-01/090000-a.json", "2026-03-02/090000-b"])
        h.appState.phase = .transcribing(progress: "")
        await h.coordinator.presentCompletedTranscription(
            TranscriptionResult(jsonPath: url, removedRecordings: ["2026-03-01/090000-a.json"], quotaPass: pass))
        #expect(h.notified.value.last?.body
                == "101500-done.json\nRemoved the audio of 2 older recordings to stay within the storage limit; transcripts are kept.")
        #expect(h.presented.value == [url], "the rename dialog still opens")
    }

    /// Nothing removed: the notice is exactly what it was.
    @Test func theCompletionNoticeIsUnchangedWhenNothingWasRemoved() async throws {
        let h = try Harness()
        let url = try plainTranscript(h)
        let pass = QuotaOutcome()
        pass.deliver(removedRecordings: [])
        h.appState.phase = .transcribing(progress: "")
        await h.coordinator.presentCompletedTranscription(TranscriptionResult(jsonPath: url, quotaPass: pass))
        #expect(h.notified.value.last?.body == "101500-done.json")
    }
}
