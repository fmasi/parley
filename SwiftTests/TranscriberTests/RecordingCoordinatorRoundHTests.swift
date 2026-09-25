import Foundation
import Testing
@testable import TranscriberCore

// Stream L, round H (items 251–262). The fake client and the harness are RecordingCoordinatorTests.swift's; `HungRead` is
// RecordingCoordinatorRoundCTests.swift's; `SlowRead`, `roundFPendingSession` and `roundFTearDown` are
// RecordingCoordinatorRoundFTests.swift's.

/// The labels of the folder work a reader ran, in the order it ran them — read once that work has finished.
final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String] = []
    func note(_ label: String) { lock.withLock { labels.append(label) } }
    var all: [String] { lock.withLock { labels } }
}

// MARK: - The quota pass runs after the record is written, fire-and-forget and bounded (251)

@MainActor
@Suite struct QuotaAfterTheWriteRoundHTests {
    private func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("quota-h-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// L review 251, IMPORTANT: a quota pass that walks a slow share for longer than the bounds — 2.5 s against 1 s — never
    /// makes the Stop's transcript "not answering": the pass runs AFTER the record is written, never queued ahead of the
    /// write. It still runs: an old archive over the quota goes.
    @Test func aSlowQuotaPassNeverFailsTheStop() async throws {
        let d = try folder(); defer { try? FileManager.default.removeItem(at: d) }
        try RecoveryFixtures.writeSessionJSON(dir: d, sessionId: "f", meetingStart: Date(), chunkIndices: [0])
        try RecoveryFixtures.writeFakeWav(at: d.appendingPathComponent("f-0.m4a"), seconds: 1)
        let old = d.appendingPathComponent("older-meeting.m4a")
        try Data(repeating: 1, count: 4_096).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: old.path)
        let state = try #require(SessionState.read(directory: d, sessionId: "f"))
        let slow = SlowRead(label: "transcript: quota", seconds: 2.5), log = ReadLog()
        let runner = TranscriptionRunner()
        runner.folderReads = FolderReads(label: "runner-h-\(UUID().uuidString)", beforeEachRead: { log.note($0); slow.delayIfNamed($0) })
        runner.folderReadSeconds = 1
        runner.folderWriteSeconds = 1
        var config = Config.default
        config.audioArchiveLimitHours = 0   // every archive not this session's is over the quota
        let result = try await runner.finalize(sessionState: state, outputDirectory: d, config: config)
        #expect(FileManager.default.fileExists(atPath: result.jsonPath.path), "the transcript is written")
        await Harness.until(within: 6) { !FileManager.default.fileExists(atPath: old.path) }
        #expect(!FileManager.default.fileExists(atPath: old.path), "the quota pass still runs")
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("f-0.m4a").path), "never this session's audio")
        let labels = log.all
        let write = try #require(labels.firstIndex(of: "transcript: write")), quota = try #require(labels.firstIndex(of: "transcript: quota"))
        #expect(write < quota, "the quota pass runs after the record is written: \(labels)")
    }

    /// … and the same through the coordinator: a salvage (a Stop's finalize, as a relaunch runs it) whose quota pass is slower
    /// than its bounds finishes, and its transcript is presented.
    @Test func aSlowQuotaPassNeverFailsASalvage() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        let p = try roundFPendingSession(h, "p")
        try RecordingSentinel.writePending([p], directory: h.tmp)
        let slow = SlowRead(label: "transcript: quota", seconds: 2.5)
        h.coordinator.folderReads = FolderReads(label: "rc-h-\(UUID().uuidString)", beforeEachRead: { slow.delayIfNamed($0) })
        h.coordinator.folderWriteDeadline = .seconds(1)
        h.coordinator.folderReadDeadline = .seconds(1)
        await h.coordinator.retryPendingSessions()
        #expect(RecordingSentinel.readPending(directory: h.tmp).isEmpty, "finished, never \"not answering\"")
        #expect(h.presented.value.map(\.lastPathComponent) == ["p.json"])
    }

    /// L review 251: the quota pass stops walking at its deadline — a spent one deletes nothing, and says it did not finish.
    @Test func aQuotaPassStopsWalkingAtItsDeadline() throws {
        let d = try folder(); defer { try? FileManager.default.removeItem(at: d) }
        for name in ["a.m4a", "b.m4a", "c.m4a"] { try Data(repeating: 1, count: 4_096).write(to: d.appendingPathComponent(name)) }
        let report = try StorageManager.enforceQuotaReport(in: d, limitHours: 0, bitrateKbps: 64, protectedFiles: [],
                                                           deadline: SuspendingClock.now - .seconds(1))
        #expect(!report.finished, "stopped at its bound")
        #expect(report.deleted.isEmpty, "a walk cut short deletes nothing it has not weighed")
        #expect(["a.m4a", "b.m4a", "c.m4a"].allSatisfy { FileManager.default.fileExists(atPath: d.appendingPathComponent($0).path) })
        let full = try StorageManager.enforceQuotaReport(in: d, limitHours: 0, bitrateKbps: 64, protectedFiles: [],
                                                         deadline: SuspendingClock.now + .seconds(30))
        #expect(full.finished && full.deleted.count == 3, "within its bound, the pass runs as before")
    }
}

// MARK: - Late audio is judged in the files' own clock (256, 260)

@MainActor
@Suite struct LateAudioClockRoundHTests {
    /// A finished session `sess` in `h`'s day folder, its leftover progress file there (a retry's gate cleans it up), and a
    /// pending entry for it.
    private func finished(_ h: Harness) async throws -> (dir: URL, transcript: URL) {
        let dir = h.tmp.appendingPathComponent("day")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "sess", meetingStart: Date(), chunkIndices: [0])
        let result = try #require(try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "sess", config: h.config.config, transcriber: FakeEngine(), diarizer: FakeDiarizer(),
            runner: h.runner))
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "sess", meetingStart: Date(), chunkIndices: [0])   // a leftover
        return (dir, result.jsonPath)
    }

    private func pend(_ h: Harness, _ dir: URL) throws {
        let s = RecordingSentinel(startedAt: Date(), sessionName: "sess", systemAudioPath: dir.appendingPathComponent("sess-0.wav").path,
                                  micAudioPath: dir.appendingPathComponent("sess-0_mic.wav").path, segment: 1, chunkIndex: 0, stopping: true)
        try RecordingSentinel.writePending([s], directory: h.tmp)
    }

    private func audio(_ name: String, in dir: URL, at date: Date) throws {
        let url = dir.appendingPathComponent(name)
        try RecoveryFixtures.writeFakeWav(at: url, seconds: 30)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func noted(_ transcript: URL) throws -> [String]? {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: transcript)) as? [String: Any])
        return ((json["metadata"] as? [String: Any])?["audio_after_transcript"] as? [String: Any])?["files"] as? [String]
    }

    /// L review 256, IMPORTANT: lateness is judged in the FILES' own clock — the finalized marker's time, written with the
    /// transcript — never the Mac's stamp against a share's file times. With the share's clock 10 minutes ahead, a chunk
    /// file written after the stamp but BEFORE the transcript (in the share's clock) is not late audio; one written after
    /// the transcript is.
    @Test func aChunkWrittenBeforeTheTranscriptInTheFilesClockIsNotLate() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        let (dir, transcript) = try await finished(h)
        let ahead = Date().addingTimeInterval(600)   // the share's clock, when it wrote the transcript and its marker
        for name in ["sess.json", ".sess.finalized"] {
            try FileManager.default.setAttributes([.modificationDate: ahead], ofItemAtPath: dir.appendingPathComponent(name).path)
        }
        try audio("sess-6.wav", in: dir, at: Date().addingTimeInterval(300))   // after the stamp, before the transcript
        try pend(h, dir)
        await h.coordinator.retryPendingSessions()
        #expect(h.appState.activeAlarms[.audioAfterTranscript] == nil, "never claimed late: \(String(describing: h.appState.activeAlarms[.audioAfterTranscript]?.message))")
        #expect(try noted(transcript) == nil, "nothing noted in the record")
        try audio("sess-7.wav", in: dir, at: Date().addingTimeInterval(900))   // after the transcript, in the share's clock
        try pend(h, dir)
        await h.coordinator.retryPendingSessions()
        #expect(h.appState.activeAlarms[.audioAfterTranscript] != nil, "real late audio is said")
        #expect(try noted(transcript) == ["sess-7.wav"])
    }

    /// L review 260 (220's fallback): a transcript with no `transcript_written_at` and no marker — written before either
    /// existed — is judged from its time as the first look found it, kept in the note: the note's own write, which moves the
    /// transcript's time past the late audio, never hides it from a later pass.
    @Test func aTranscriptWithoutAStampIsJudgedFromTheNotesReference() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        let (dir, transcript) = try await finished(h)
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: transcript)) as? [String: Any])
        var metadata = try #require(json["metadata"] as? [String: Any])
        metadata[TranscriptAssembler.writtenAtKey] = nil
        json["metadata"] = metadata
        try TranscriptAssembler.write(json, to: transcript)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: transcript.path)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".sess.finalized"))
        try audio("sess-7.wav", in: dir, at: Date().addingTimeInterval(-60))
        try pend(h, dir)
        await h.coordinator.retryPendingSessions()
        #expect(try noted(transcript) == ["sess-7.wav"], "said from the transcript's own time")
        h.appState.acknowledge(.audioAfterTranscript)
        #expect(try FileManager.default.attributesOfItem(atPath: transcript.path)[.modificationDate] as? Date ?? .distantPast > Date().addingTimeInterval(-30),
                "the note's write moved the transcript's time past the late audio")
        try pend(h, dir)
        await h.coordinator.retryPendingSessions()
        #expect(h.appState.activeAlarms[.audioAfterTranscript] != nil, "still said: the note's reference")
    }
}

// MARK: - The Quit's LaunchAgent keep is decided from what is on disk, at every exit (257)

@MainActor
@Suite struct QuitKeepFromPersistedStateRoundHTests {
    private func held(_ h: Harness) -> Bool { RecordingSentinel.readPending(directory: h.tmp).contains { $0.heldReason != nil } }
    private func saidHeld(_ h: Harness) -> Bool {
        h.notified.value.contains { $0.body.contains("A previous recording is still being stopped; Parley will finish it next time") }
    }

    /// L review 257 (a): a hold that lands while the Quit's alert is still up — before the Quit is under way — keeps the
    /// LaunchAgent and is said: the keep is read from the pending list, never from whether the hold came during the Quit.
    @Test func aHoldThatLandsWhileTheQuitAlertIsUpKeepsTheLaunchAgent() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID(); s.stopping = true
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.isCapturingResult = true
        h.coordinator.helperStopDeadline = .milliseconds(300)
        h.client.onStop = { try? await Task.sleep(for: .seconds(1)) }   // the helper will not let go
        let coordinator = h.coordinator, tmp = h.tmp
        let launch = Task { await coordinator.recoverAtLaunch() }
        await Harness.until { coordinator.relaunchFoundCapture }
        #expect(coordinator.relaunchFoundCapture)
        let quit = await coordinator.prepareForQuit(confirm: {
            await Harness.until { RecordingSentinel.readPending(directory: tmp).contains { $0.heldReason != nil } }
            return true
        })
        await launch.value
        #expect(quit)
        #expect(held(h), "held while the alert was up")
        #expect(coordinator.keepsLaunchAgentOnQuit, "the LaunchAgent stays, so the next launch finishes it")
        #expect(saidHeld(h), "\(h.notified.value)")
    }

    /// L review 257 (c): an IDLE Quit — nothing asked, nothing stopped — with a held session already pending keeps the
    /// LaunchAgent and says so: the early return decides it too.
    @Test func anIdleQuitWithAHeldSessionPendingKeepsTheLaunchAgent() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        var p = try roundFPendingSession(h, "p")
        p.heldReason = .relaunch
        try RecordingSentinel.writePending([p], directory: h.tmp)
        #expect(await h.coordinator.prepareForQuit(confirm: { Issue.record("an idle Quit asks nothing"); return true }))
        #expect(h.coordinator.keepsLaunchAgentOnQuit)
        #expect(saidHeld(h), "\(h.notified.value)")
    }

    /// L review 257 (b): the Quit's bound runs out while the helper still has not answered its stop — the recording's file
    /// marked stopping — before any hold: the LaunchAgent is kept all the same.
    @Test func aQuitWhoseBoundRunsOutBeforeTheHelperLetsGoKeepsTheLaunchAgent() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { roundFTearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.coordinator.quitStopBound = .milliseconds(200)
        h.client.onStop = { try? await Task.sleep(for: .seconds(1)) }
        #expect(await h.coordinator.prepareForQuit(confirm: { true }))
        #expect(RecordingSentinel.read(directory: h.tmp)?.stopping == true)
        #expect(h.coordinator.keepsLaunchAgentOnQuit, "the helper had not let go")
        await Harness.until(within: 5) { h.appState.isIdle }   // the Stop ends on its own
    }

    /// … while a Quit whose recording was stopped and finished within its bound keeps none.
    @Test func aQuitThatFinishedItsRecordingKeepsNoLaunchAgent() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { roundFTearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(await h.coordinator.prepareForQuit(confirm: { true }))
        #expect(!h.coordinator.keepsLaunchAgentOnQuit)
        #expect(!saidHeld(h))
    }
}

// MARK: - Every name fits: the session's base name and every temporary (262, 268)

@MainActor
@Suite struct LongNamesRoundHTests {
    private func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("names-h-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A 250-byte CJK meeting title: 83 three-byte characters and one byte.
    private let cjkTitle = String(repeating: "会", count: 83) + "x"

    /// L review 262, IMPORTANT: a long title's session name is capped so that every file named from it — its summary, and the
    /// longest, a damaged summary kept aside under a unique name — fits in 255 BYTES (a share, a Linux server count bytes).
    /// Cut on a character boundary, and two long titles that share their start never get the same name.
    @Test func aLongCJKTitlesSessionNameFitsEveryFileNamedFromIt() {
        #expect(cjkTitle.utf8.count == 250)
        let naming = RecordingCoordinator.startNaming(sessionName: cjkTitle, now: Date())
        let id = naming.chunkBaseName
        for derived in ["\(id)-summary.md", "\(id)-summary.damaged-\(UUID().uuidString).md", "\(id).damaged-\(UUID().uuidString).json.bak",
                        "session-\(id).\(UUID().uuidString).json", "\(id).relaunch-99.diag.jsonl", "\(id)-99999_mic.wav"] {
            #expect(derived.utf8.count <= 255, "\(derived.utf8.count) bytes: \(derived)")
        }
        let kept = String(naming.sanitized.dropLast(9))   // "-" and the whole title's hash follow the kept prefix
        #expect(!kept.isEmpty && cjkTitle.hasPrefix(kept), "a prefix of whole characters: \(naming.sanitized)")
        let other = RecordingCoordinator.startNaming(sessionName: String(repeating: "会", count: 83) + "y", now: Date())
        #expect(other.sanitized != naming.sanitized, "unique: the whole title's hash")
        #expect(RecordingCoordinator.startNaming(sessionName: "Weekly Sync", now: Date()).sanitized == "Weekly Sync", "a name that fits is unchanged")
    }

    /// L review 262: such a session records AND writes its transcript — its record, marker and format file under names that
    /// fit, and no temporary left.
    @Test func aLongTitlesSessionWritesItsTranscript() async throws {
        let d = try folder(); defer { try? FileManager.default.removeItem(at: d) }
        let id = RecordingCoordinator.startNaming(sessionName: String(repeating: "a", count: 250), now: Date()).chunkBaseName
        try RecoveryFixtures.writeSessionJSON(dir: d, sessionId: id, meetingStart: Date(), chunkIndices: [0])
        try RecoveryFixtures.writeFakeWav(at: d.appendingPathComponent("\(id)-0.m4a"), seconds: 1)
        let state = try #require(SessionState.read(directory: d, sessionId: id))
        let runner = TranscriptionRunner()
        runner.folderReads = FolderReads(label: "names-h-\(UUID().uuidString)")
        let result = try await runner.finalize(sessionState: state, outputDirectory: d, config: .default)
        #expect(FileManager.default.fileExists(atPath: result.jsonPath.path))
        #expect(SessionState.isMarkedFinalized(directory: d, sessionId: id))
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.path).filter { $0.hasSuffix(".tmp") }.isEmpty, "no temporary left")
    }

    /// L review 262: every temporary name is short — a durable write of a file whose own name is near the limit (a session
    /// named before the cap) still lands — and keeps a short prefix of its file's name (L review 268), so the session's sweep
    /// finds a stale one, in the old form too.
    @Test func aDurableWriteNearTheNameLimitLandsAndItsStaleTemporariesAreSwept() throws {
        let d = try folder(); defer { try? FileManager.default.removeItem(at: d) }
        let id = "120000-" + String(repeating: "b", count: 240)   // "<id>.json" is 252 bytes
        let transcript = d.appendingPathComponent("\(id).json")
        try TranscriptAssembler.write(data: Data("{}".utf8), to: transcript)
        #expect(FileManager.default.fileExists(atPath: transcript.path), "written, never ENAMETOOLONG")
        let temporary = DurableFile.temporaryName(for: "\(id).json")
        #expect(temporary.utf8.count <= 110 && temporary.hasPrefix(".120000-bbbb") && temporary.hasSuffix(".tmp"), "\(temporary)")
        try Data().write(to: d.appendingPathComponent(temporary))   // a write that died
        let short = "s.json.\(UUID().uuidString).tmp"                    // the old form, a short session's
        try RecoveryFixtures.writeSessionJSON(dir: d, sessionId: "s", meetingStart: Date(), chunkIndices: [])
        try Data().write(to: d.appendingPathComponent(short))
        SessionState.sweepTemporaries(directory: d, sessionId: id)
        SessionState.sweepTemporaries(directory: d, sessionId: "s")
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.path).filter { $0.hasSuffix(".tmp") }.isEmpty, "swept")
    }

    /// L review 268 (245): the evidence record's temporary keeps a short prefix of its session's name, and a stale one — a
    /// write that died — is swept by the session's next record.
    @Test func anEvidenceRecordsTemporaryIsItsSessionsAndIsSwept() throws {
        let d = try folder(); defer { try? FileManager.default.removeItem(at: d) }
        let stale = SessionEvidence.temporaryName(sessionId: "meeting")
        #expect(stale.hasPrefix(".meeting") && stale.hasSuffix(".tmp"), "\(stale)")
        #expect(SessionEvidence.temporaryName(sessionId: String(repeating: "c", count: 250)).utf8.count <= 110)
        try Data().write(to: d.appendingPathComponent(stale))
        let other = SessionEvidence.temporaryName(sessionId: "other")
        try Data().write(to: d.appendingPathComponent(other))
        _ = try SessionEvidence.writeRecord(Data("x".utf8), sessionId: "meeting", directory: d, own: SessionEvidence.OwnRecords(), files: .live)
        let left = try FileManager.default.contentsOfDirectory(atPath: d.path).filter { $0.hasSuffix(".tmp") }
        #expect(left == [other], "this session's stale temporary is swept, never another session's: \(left)")
    }
}
