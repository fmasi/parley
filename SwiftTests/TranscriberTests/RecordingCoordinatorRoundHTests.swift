import Foundation
import Testing
@testable import TranscriberCore

// Stream L, round H (items 251–262). The fake client and the harness are RecordingCoordinatorTests.swift's, and
// `HungStep` too; `SlowRead`, `roundFPendingSession` and `roundFTearDown` are
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
        let helper = HungStep()   // the helper will not let go until released
        defer { helper.release() }
        h.client.onStop = { await helper.hangAwaited() }
        let coordinator = h.coordinator, tmp = h.tmp
        let launch = Task { await coordinator.recoverAtLaunch() }
        await Harness.until { coordinator.relaunchFoundCapture }
        #expect(coordinator.relaunchFoundCapture)
        let quit = await coordinator.prepareForQuit(confirm: {
            await Harness.until { RecordingSentinel.readPending(directory: tmp).contains { $0.heldReason != nil } }
            return true
        })
        await launch.value
        #expect(helper.isHanging, "by order: held while the helper's stop was still unanswered")
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
        let helper = HungStep()   // the helper's stop hangs until released
        defer { helper.release() }
        h.client.onStop = { await helper.hangAwaited() }
        // The Quit's own mark and its look for a held session are WAITED for, whatever the machine's load (#298). The
        // `stopping` read below is the Stop's mark, which the Stop awaits before it asks the helper.
        h.coordinator.exitMarkBound = .seconds(60)
        #expect(await h.coordinator.prepareForQuit(confirm: { true }))
        #expect(helper.isHanging, "by order: the Quit returned with the helper's stop still unanswered")
        #expect(RecordingSentinel.read(directory: h.tmp)?.stopping == true)
        #expect(h.coordinator.keepsLaunchAgentOnQuit, "the helper had not let go")
        helper.release()   // the helper answers: the Stop ends
        await Harness.until(within: 5) { h.appState.isIdle }
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

// MARK: - A second session's row is never dropped (261)

@MainActor
@Suite struct SessionRowsAppendRoundHTests {
    /// L review 261: a per-session past event — a recording STOPPED, audio kept after a transcript — raised while its kind's
    /// row is still up (not acknowledged) is ADDED to that row, never dropped; the same message twice is said once.
    @Test func aSecondSessionsMessageIsAddedToTheRow() {
        for kind in [AlarmKind.recordingStopped, .audioAfterTranscript] {
            var registry = CaptureAlarmRegistry()
            let first = registry.raise(kind, message: "About p.json.", now: Date())
            let second = registry.raise(kind, message: "About q.json.", now: Date())
            #expect(first && second, "said: \(kind)")
            let message = registry.alarms[kind]?.message ?? ""
            #expect(message.contains("p.json") && message.contains("q.json"), "\(message)")
            let again = registry.raise(kind, message: "About q.json.", now: Date())
            #expect(!again && registry.alarms[kind]?.message == message, "the same message is said once")
        }
        var registry = CaptureAlarmRegistry()   // a live condition's row is still raised once
        registry.raise(.diskLow, message: "a", now: Date())
        let repeated = registry.raise(.diskLow, message: "b", now: Date())
        #expect(!repeated && registry.alarms[.diskLow]?.message == "a")
    }

    /// L review 261: two passes, each finishing a different session while the first row is still up — both are named, and
    /// the second is presented again.
    @Test func twoPassesNameBothSessions() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        try RecordingSentinel.writePending([try roundFPendingSession(h, "p")], directory: h.tmp)
        await h.coordinator.retryPendingSessions()
        #expect(h.appState.activeAlarms[.recordingStopped]?.message.contains("p.json") == true)
        let shownBefore = try #require(h.appState.activeAlarms[.recordingStopped]?.lastNotifiedAt, "presented")
        try RecordingSentinel.writePending([try roundFPendingSession(h, "q")], directory: h.tmp)
        await h.coordinator.retryPendingSessions()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("p.json") && row.contains("q.json"), "both sessions are named: \(row)")
        #expect((h.appState.activeAlarms[.recordingStopped]?.lastNotifiedAt ?? .distantPast) > shownBefore, "the added session is presented")
    }
}

// MARK: - The waiting row's remedy is never stale (255)

@MainActor
@Suite struct WaitingRemedyRoundHTests {
    private let setup = "after Setup or a model download", another = "choose another engine in Settings"

    /// L review 255: the waiting row is said again when its REMEDY changes — the engine chosen now cannot be made here — and
    /// the stale remedy goes from the row, never left beside the new one. Acknowledged, a new remedy is said again too.
    @Test func theWaitingRowIsSaidAgainWhenItsRemedyChanges() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        let p = try roundFPendingSession(h, "p", orphan: true)
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.engine.value = NotReadyEngine()
        await h.coordinator.retryPendingSessions()
        #expect(h.appState.activeAlarms[.recordingStopped]?.message.contains(setup) == true)
        h.engineError.value = TranscriptionRunner.RunnerError.engineUnavailable("SpeechAnalyzer requires macOS 26")   // another engine chosen
        await h.coordinator.transcriptionEngineMayBeReady()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains(another) && !row.contains(setup), "the new remedy, never the stale one: \(row)")
        h.appState.acknowledge(.recordingStopped)
        h.engineError.value = nil   // the model engine again: not downloaded
        await h.coordinator.transcriptionEngineMayBeReady()
        let again = try #require(h.appState.activeAlarms[.recordingStopped]?.message, "said again once acknowledged")
        #expect(again.contains(setup) && !again.contains(another), "\(again)")
        await h.coordinator.transcriptionEngineMayBeReady()
        #expect(h.appState.activeAlarms[.recordingStopped]?.message == again, "the same remedy is said once")
    }
}

// MARK: - The merge's checks: blocking file work on the folder's queue, and a late check claimed once (252, 253)

/// A merge's steps, run in order on one serial queue — as the folder's queue runs them — and recorded: which ran as blocking
/// file work (`run`) and which as AVFoundation's loads (`runAsync`). `late`: the steps whose bound runs out — how, per label.
final class MergeStepsProbe: MergeFileSteps, @unchecked Sendable {
    enum Late { case beforeTheStep, asTheStepFinishes }
    private let queue = DispatchQueue(label: "merge-steps-h-\(UUID().uuidString)")
    private let lock = NSLock()
    private var runs: [String] = [], asyncs: [String] = []
    let late: @Sendable (String) -> Late?
    init(late: @escaping @Sendable (String) -> Late? = { _ in nil }) { self.late = late }
    var blocking: [String] { lock.withLock { runs } }
    var loads: [String] { lock.withLock { asyncs } }
    /// Returns once every step queued so far has run.
    func settle() { queue.sync {} }

    func run<T>(_ label: String, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        lock.withLock { runs.append(label) }
        return try await onQueue(label) { try work() }
    }

    func runAsync<T>(_ label: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        lock.withLock { asyncs.append(label) }
        return try await onQueue(label) {
            let box = Box<T>(), done = DispatchSemaphore(value: 0)
            Task.detached { do { box.value = .success(try await work()) } catch { box.value = .failure(error) }; done.signal() }
            done.wait()
            return try box.value!.get()
        }
    }

    private final class Box<T>: @unchecked Sendable { var value: Result<T, Error>? }

    private func onQueue<T>(_ label: String, _ step: @escaping @Sendable () throws -> T) async throws -> T {
        switch late(label) {
        case .beforeTheStep?:
            queue.async { Thread.sleep(forTimeInterval: 0.2); _ = try? step() }   // it answers after its caller gave up
            throw AudioConcatenatorError.folderNotAnswering(label)
        case .asTheStepFinishes?:
            queue.sync { _ = try? step() }   // it finished — and the bound ran out in the same instant
            throw AudioConcatenatorError.folderNotAnswering(label)
        case nil:
            return try queue.sync { try step() }
        }
    }
}

@MainActor
@Suite(.serialized) struct MergeChecksRoundHTests {
    private func chunks() async throws -> (dir: URL, chunks: [ChunkAudio]) {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("merge-h-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let t0 = Date()
        var list: [ChunkAudio] = []
        for i in 0..<2 {
            let url = d.appendingPathComponent("m-\(i).m4a")
            try await AudioConcatenatorTests.createTestM4a(at: url)
            list.append(ChunkAudio(url: url, startTime: t0.addingTimeInterval(Double(i))))
        }
        return (d, list)
    }

    /// L review 252, IMPORTANT: the output's checks run their blocking file work — is it there, its size, its decoded length,
    /// its removal — as blocking steps on the folder's queue; only AVFoundation's loads (the sources', the output's tracks and
    /// played length) are asynchronous steps. Never blocking file work on the cooperative pool.
    @Test func onlyTheLoadsAreAsynchronousSteps() async throws {
        let (d, list) = try await chunks(); defer { try? FileManager.default.removeItem(at: d) }
        let probe = MergeStepsProbe()
        _ = try await AudioConcatenator.concatenate(chunks: list, outputDirectory: d, outputName: "m", deleteSources: true, steps: probe)
        #expect(probe.loads.allSatisfy { $0.hasSuffix("loads") }, "only loads are asynchronous: \(probe.loads)")
        #expect(probe.loads.contains("merge: sources loads") && probe.loads.contains("merge: check output loads"), "\(probe.loads)")
        #expect(probe.blocking.contains("merge: check output") && probe.blocking.contains("merge: check output decoded"), "\(probe.blocking)")
    }

    /// L review 253: a check that FINISHES in the very instant its bound runs out is claimed once — by the check: the merge it
    /// verified is used and listed, never left on disk unlisted.
    @Test func aCheckThatFinishesAsItsBoundRunsOutIsItsOwn() async throws {
        let (d, list) = try await chunks(); defer { try? FileManager.default.removeItem(at: d) }
        let probe = MergeStepsProbe(late: { $0.hasPrefix("merge: check output") ? .asTheStepFinishes : nil })
        let result = try await AudioConcatenator.concatenate(chunks: list, outputDirectory: d, outputName: "m", deleteSources: false, steps: probe)
        #expect(result.outputPath.lastPathComponent == "m.m4a" && FileManager.default.fileExists(atPath: result.outputPath.path), "listed")
    }

    /// L review 253/255: a check that answers only after its caller gave up — the merge skipped, its chunk files listed —
    /// removes nothing itself; the output it checked is removed behind it, on the folder's queue: never an unlisted merge.
    @Test func anOutputWhoseCheckAnsweredLateIsRemoved() async throws {
        let (d, list) = try await chunks(); defer { try? FileManager.default.removeItem(at: d) }
        let probe = MergeStepsProbe(late: { $0 == "merge: check output decoded" ? .beforeTheStep : nil })
        await #expect(throws: AudioConcatenatorError.self) {
            _ = try await AudioConcatenator.concatenate(chunks: list, outputDirectory: d, outputName: "m", deleteSources: true, steps: probe)
        }
        await Harness.until { probe.settle(); return !FileManager.default.fileExists(atPath: d.appendingPathComponent("m.m4a").path) }
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("m.m4a").path), "removed behind the late check")
        #expect(list.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }, "the chunk files are the audio")
    }

    /// L review 255 (231): a `merge: delete sources` that does not answer keeps the merge: it was verified, and it is listed.
    @Test func aTimedOutDeleteOfTheSourcesKeepsTheMerge() async throws {
        let (d, list) = try await chunks(); defer { try? FileManager.default.removeItem(at: d) }
        let probe = MergeStepsProbe(late: { $0 == "merge: delete sources" ? .beforeTheStep : nil })
        let result = try await AudioConcatenator.concatenate(chunks: list, outputDirectory: d, outputName: "m", deleteSources: true, steps: probe)
        #expect(FileManager.default.fileExists(atPath: result.outputPath.path), "the merge is kept and listed")
        probe.settle()
    }
}

// MARK: - SpeechAnalyzer looks at what is installed first, and a look that does not answer is not ready (254)

/// A speech-model inventory that counts its looks — and whose installed-locales look can hang.
final class LookingSpeechInventory: SpeechAssetInventory, @unchecked Sendable {
    private let lock = NSLock()
    private var supportedAsked = 0
    let installed: [String]
    let hangs: Bool
    init(installed: [String] = [], hangs: Bool = false) { self.installed = installed; self.hangs = hangs }
    var supportedLooks: Int { lock.withLock { supportedAsked } }
    func installedLocales() async -> [String] {
        if hangs { try? await Task.sleep(for: .seconds(30)) }
        return installed
    }
    func supportedLocales() async -> [String] {
        lock.withLock { supportedAsked += 1 }
        return ["en-US"]
    }
    func install(locale: String) async throws { Issue.record("never an install") }
}

#if compiler(>=6.2)
@MainActor
@Suite struct SpeechAnalyzerLooksRoundHTests {
    /// L review 254: a transcription looks at the INSTALLED locales first — an installed model needs no other look — and a
    /// model that is not installed is refused, the supported locales looked at only to word it (L review 270).
    @Test func aTranscriptionLooksAtTheInstalledModelsFirst() async throws {
        guard #available(macOS 26.0, *) else { return }
        let installed = LookingSpeechInventory(installed: ["en-US"])
        _ = try? await SpeechAnalyzerEngine(language: "en", inventory: installed)
            .transcribe(audioPath: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).wav"), language: nil, audioSource: .system)
        #expect(installed.supportedLooks == 0, "installed: no other look")
        let missing = LookingSpeechInventory()
        await #expect(throws: SpeechAnalyzerError.self) {
            _ = try await SpeechAnalyzerEngine(language: "en", inventory: missing)
                .transcribe(audioPath: URL(fileURLWithPath: "/nonexistent.wav"), language: nil, audioSource: .system)
        }
        #expect(missing.supportedLooks == 1, "not installed: the supported look only words the refusal (L review 270)")
    }

    /// L review 254: a salvage's readiness look is bounded — an inventory that does not answer is NOT READY: the session
    /// waits, said, within the bound.
    @Test func aReadinessLookThatDoesNotAnswerIsNotReady() async throws {
        guard #available(macOS 26.0, *) else { return }
        let h = try Harness()
        defer { roundFTearDown(h) }
        let p = try roundFPendingSession(h, "p", orphan: true)
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.engine.value = SpeechAnalyzerEngine(language: "en", inventory: LookingSpeechInventory(installed: ["en-US"], hangs: true))
        h.coordinator.engineReadyDeadline = .milliseconds(300)
        let started = ContinuousClock.now
        await h.coordinator.retryPendingSessions()
        #expect(ContinuousClock.now - started < .seconds(5), "within its bound")
        #expect(RecordingSentinel.readPending(directory: h.tmp).map(\.sessionKey) == [p.sessionKey], "kept")
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("couldn’t check the speech model yet"), "honestly worded (L review 270): \(row)")
    }
}
#endif

// MARK: - Why a session was kept survives a Start that got in (258)

@MainActor
@Suite struct KeptWhileWritingRoundHTests {
    /// L review 258 (228): a salvage whose transcript write does not answer while the user began a Start meanwhile (its name
    /// asked for) yields to that Start — and the session it keeps still says it was kept WHILE WRITING, so the write that
    /// lands later is said.
    @Test func aStartThatGotInNeverDropsWhyTheSessionWasKept() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        let p = try roundFPendingSession(h, "p", orphan: true)
        try RecordingSentinel.writePending([p], directory: h.tmp)
        let hung = HungStep("transcript: write")
        defer { hung.release() }
        h.coordinator.folderReads = FolderReads(label: "rc-h-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        h.coordinator.folderWriteDeadline = .milliseconds(300)
        let coordinator = h.coordinator, client = h.client
        client.onFinalizeDiagnostics = {
            client.onFinalizeDiagnostics = nil
            coordinator.announceStart()   // the user pressed Record: the name is being asked for
        }
        await h.coordinator.retryPendingSessions()
        #expect(h.coordinator.userStartInFlight, "the Start got in")
        let kept = try #require(RecordingSentinel.readPending(directory: h.tmp).first { $0.sessionKey == p.sessionKey })
        #expect(kept.keptWhileWriting?.chunkCount == 2, "why it was kept survives: \(String(describing: kept.keptWhileWriting))")
    }
}

// MARK: - The power-off withdraw clears every mark this process set (259)

@MainActor
@Suite struct PowerOffMarksRoundHTests {
    /// L review 259 (221): this process marked TWO sessions — one, then the next once the first went to the pending list —
    /// and the withdraw clears both, never only the last.
    @Test func theWithdrawClearsEverySessionThisProcessMarked() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        h.coordinator.powerOffMarkWindow = .seconds(30)   // withdrawn by hand below
        h.coordinator.exitMarkBound = .seconds(60)   // the synchronous mark is WAITED for, whatever the machine's load (#298)
        var first = try h.writeSentinel(sessionId: "one")
        first.stopping = true
        try RecordingSentinel.write(first, directory: h.tmp)
        h.coordinator.markPowerOffDuringFinalize()
        var marked = try #require(RecordingSentinel.read(directory: h.tmp))
        #expect(marked.quitMarkedByPowerOff)
        marked.stopping = true
        try RecordingSentinel.writePending([marked], directory: h.tmp)   // its session goes to the pending list, the mark with it
        var second = try h.writeSentinel(sessionId: "two")
        second.stopping = true
        try RecordingSentinel.write(second, directory: h.tmp)
        h.coordinator.markPowerOffDuringFinalize()
        #expect(RecordingSentinel.read(directory: h.tmp)?.quitMarkedByPowerOff == true)
        await h.coordinator.withdrawPowerOffMark()
        #expect(RecordingSentinel.read(directory: h.tmp)?.quitDuringFinalize == false, "the second mark is withdrawn")
        #expect(RecordingSentinel.readPending(directory: h.tmp).first?.quitDuringFinalize == false, "and the first, from its pending entry")
    }
}

// MARK: - A failed restart's hold reads its session before the app goes idle (264)

@MainActor
@Suite struct RestartHoldOwnershipRoundHTests {
    /// L review 264 (242): a failed restart whose helper will not stop holds its session — and reads that session BEFORE the
    /// app goes idle, so nothing is awaited between the idle phase and the hold's end of the capture: no Start can get in
    /// and have its crash detection disarmed.
    @Test func aFailedRestartsHoldReadsItsSessionBeforeTheAppGoesIdle() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { roundFTearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "mic-1")
        h.client.startError = CaptureCallTimeout(call: "start", seconds: 15)
        h.coordinator.helperStopDeadline = .milliseconds(100)
        let helper = HungStep()   // the helper will not stop until released
        defer { helper.release() }
        h.client.onStop = { await helper.hangAwaited() }
        let reads = Harness.Box(0), idleDuringTheHoldsRead = Harness.Box<Bool?>(nil), appState = h.appState
        h.coordinator.sentinelIO = SentinelIO(label: "rc-h-\(UUID().uuidString)", beforeEach: { label in
            guard label == "crash: read" else { return }
            reads.value += 1   // on the queue: one at a time
            guard reads.value == 2 else { return }   // the hold's own read
            idleDuringTheHoldsRead.value = DispatchQueue.main.sync { MainActor.assumeIsolated { appState.isIdle } }
        })
        await h.coordinator.handleXPCCrash()
        #expect(helper.isHanging, "by order: held while the helper's stop was still unanswered")
        #expect(RecordingSentinel.readPending(directory: h.tmp).first?.heldReason == .restartFailed, "held")
        #expect(idleDuringTheHoldsRead.value == false, "read while the recording's phase still refused a Start")
    }
}

// MARK: - A Stop is always kept apart when its mark may not land (265, 266, 267)

@MainActor
@Suite struct StopKeptApartRoundHTests {
    private func request(_ h: Harness) -> RecordingSentinel.StopRequest? { RecordingSentinel.readStopRequest(directory: h.tmp) }

    /// L review 265 (236): the stop kept apart is remembered only once its file is WRITTEN — a write that failed is tried
    /// again at the next mark that does not answer, never taken for done.
    @Test func aStopRequestWhoseWriteFailedIsWrittenAtTheNextMark() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { roundFTearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let key = try #require(RecordingSentinel.read(directory: h.tmp)).sessionKey
        let stuck = StuckSentinelQueue(["mark stopping"])
        defer { stuck.release() }
        h.coordinator.sentinelIO = stuck.io
        h.coordinator.sentinelDeadline = .milliseconds(200)
        let blocker = h.tmp.appendingPathComponent("stop-requested.json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)   // the write fails
        await h.coordinator.markSentinelStoppingOffMain()
        #expect(request(h) == nil)
        try FileManager.default.removeItem(at: blocker)
        await h.coordinator.markSentinelStoppingOffMain()   // the mark still does not answer
        #expect(request(h)?.sessionKey == key, "written this time")
    }

    /// L review 266: a Stop deferred while a crash restart runs only queues its mark — so it always keeps the stop apart too,
    /// from the recording's key kept in memory since its start.
    @Test func aStopDeferredDuringRecoveryIsKeptApart() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { roundFTearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let key = try #require(RecordingSentinel.read(directory: h.tmp)).sessionKey
        h.client.stopError = FakeCaptureError()
        let coordinator = h.coordinator, tmp = h.tmp
        let keptWhileRestarting = Harness.Box<String?>(nil)
        h.client.onStartAsync = {
            await coordinator.stopRecording()   // deferred: recovery is in flight
            await coordinator.settleStopRequestIOForTesting()
            keptWhileRestarting.value = RecordingSentinel.readStopRequest(directory: tmp)?.sessionKey
        }
        await h.coordinator.handleXPCCrash()
        #expect(keptWhileRestarting.value == key, "kept apart while the restart ran")
    }

    /// L review 266: a Stop with no live pipeline (a re-attach that could not set one up) whose recovery file does not answer
    /// still knows its recording — kept in memory since the re-attach — and keeps the stop apart, never only a log line.
    @Test func aStopWithNoPipelineAndNoRecoveryFileIsKeptApart() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.isCapturingResult = true
        h.runner.failSetupForTesting = true
        await h.coordinator.recoverAtLaunch()
        #expect(h.appState.isRecording && h.runner.chunkRotator == nil, "re-attached without a pipeline")
        let stuck = StuckSentinelQueue()
        defer { stuck.release() }
        h.coordinator.sentinelIO = stuck.io
        h.coordinator.sentinelDeadline = .milliseconds(200)
        let client = h.client, dead = Harness.Box<CheckedContinuation<Void, Never>?>(nil)
        client.onStop = { await withCheckedContinuation { dead.value = $0 } }
        let coordinator = h.coordinator
        let stopping = Task { await coordinator.stopRecording() }
        await Harness.until { dead.value != nil }
        await h.coordinator.settleStopRequestIOForTesting()
        #expect(request(h)?.sessionKey == s.sessionKey, "kept apart: \(String(describing: request(h)))")
        stuck.release()
        client.onStop = nil
        dead.value?.resume()
        await stopping.value
    }

    /// L review 267: a Stop whose mark did not answer, but which then finishes normally — its recovery file deleted — clears
    /// the stop it kept apart.
    @Test func aNormalStopClearsTheStopItKeptApart() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { roundFTearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let call = try #require(h.client.startCalls.first)   // the helper hands back its first chunk: a normal Stop
        try FileManager.default.createDirectory(at: call.outputDirectory, withIntermediateDirectories: true)
        let sys = call.outputDirectory.appendingPathComponent(call.baseName + ".wav"), mic = call.outputDirectory.appendingPathComponent(call.baseName + "_mic.wav")
        try Harness.headerOnlyWAV().write(to: sys); try Harness.headerOnlyWAV().write(to: mic)
        h.client.stopResult = AudioPaths(systemAudio: sys, micAudio: mic)
        let stuck = StuckSentinelQueue(["mark stopping"])
        defer { stuck.release() }
        h.coordinator.sentinelIO = stuck.io
        h.coordinator.sentinelDeadline = .milliseconds(200)
        let tmp = h.tmp, keptDuringTheStop = Harness.Box(false)
        h.client.onStop = {
            keptDuringTheStop.value = RecordingSentinel.readStopRequest(directory: tmp) != nil
            stuck.release()   // the recovery file answers again: the Stop's delete lands
        }
        await h.coordinator.stopRecording()
        await h.coordinator.settleStopRequestIOForTesting()
        #expect(RecordingSentinel.read(directory: h.tmp) == nil && h.presented.value.count == 1, "a normal Stop: transcribed, its recovery file deleted")
        #expect(keptDuringTheStop.value, "kept apart while the mark did not answer")
        #expect(request(h) == nil, "cleared once the Stop finished")
    }

    /// … and a Stop that failed — the helper had already let go — whose salvage settled the recording clears it too.
    @Test func aFailedStopsSalvageClearsTheStopItKeptApart() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { roundFTearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let stuck = StuckSentinelQueue(["mark stopping"])
        defer { stuck.release() }
        h.coordinator.sentinelIO = stuck.io
        h.coordinator.sentinelDeadline = .milliseconds(200)
        let tmp = h.tmp, keptDuringTheStop = Harness.Box(false)
        h.client.onStop = {
            keptDuringTheStop.value = RecordingSentinel.readStopRequest(directory: tmp) != nil
            stuck.release()
        }
        await h.coordinator.stopRecording()   // "no capture in progress": salvaged from disk
        await h.coordinator.settleStopRequestIOForTesting()
        #expect(RecordingSentinel.read(directory: h.tmp) == nil, "settled")
        #expect(keptDuringTheStop.value && request(h) == nil, "kept apart, then cleared")
    }

    /// L review 267: a relaunch that finds no recovery file for the stop kept apart — the recording's fate settled by another
    /// path — clears that stale file.
    @Test func aRelaunchClearsAStaleStopRequest() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        try RecordingSentinel.writeStopRequest(RecordingSentinel.StopRequest(sessionKey: "/gone/sess", requestedAt: Date()), directory: h.tmp)
        await h.coordinator.recoverAtLaunch()
        await h.coordinator.settleStopRequestIOForTesting()
        #expect(request(h) == nil)
    }
}

// MARK: - Small items (268)

@MainActor
@Suite struct SmallItemsRoundHTests {
    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("small-h-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// L review 268: chunks a Stop could not check MAY hold audio — their row's headline says only what is certain, never
    /// "Audio kept" — while audio recorded after a transcript keeps its own.
    @Test func theUncheckedChunksRowsHeadlineIsHonest() {
        #expect(AlarmKind.possibleAudioAfterTranscript.headline == "Possible audio after a transcript")
        #expect(AlarmKind.possibleAudioAfterTranscript.isAcknowledgeable && AlarmKind.possibleAudioAfterTranscript.outlivesRecording)
        #expect(AlarmKind.possibleAudioAfterTranscript.addsPerSession)
        #expect(AlarmKind.audioAfterTranscript.headline == "Audio kept after a transcript")
    }

    /// L review 268 (246): a late write that lands AFTER the commit — which kept the live log, the record not written yet —
    /// clears the mark at once and lets that lingering live log go.
    @Test func aLateWriteThatLandsAfterTheCommitLetsTheLiveLogGo() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let hung = HungStep("evidence: build"), once = Harness.Box(true)
        defer { hung.release() }
        let evidence = SessionEvidence(folderReads: FolderReads(label: "evidence-h-\(UUID().uuidString)", beforeEachRead: { name in
            guard once.value, name == hung.label else { return }
            once.value = false
            hung.hangIfNamed(name)
        }))
        evidence.folderDeadline = 0.2
        evidence.beginCapture(sessionId: "s", directory: d)
        evidence.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
        LiveDiagnosticsLog.flushAll()
        _ = await evidence.finalize(sessionId: "s", directory: d)   // timed out: marked unwritten
        evidence.commit(sessionId: "s", directory: d)               // the live log is its only record: kept
        LiveDiagnosticsLog.flushAll()
        let live = d.appendingPathComponent("s.diag.live.jsonl")
        #expect(FileManager.default.fileExists(atPath: live.path), "kept while the record is not written")
        hung.release()   // the write lands
        await Harness.until { LiveDiagnosticsLog.flushAll(); return !FileManager.default.fileExists(atPath: live.path) }
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("s.diag.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: live.path), "the lingering live log goes once the record is on disk")
    }

    /// L review 268 (247): why a session was held is recorded once per session — never again at every salvage attempt.
    @Test func whyASessionWasHeldIsRecordedOnce() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        var p = try roundFPendingSession(h, "p")
        p.heldReason = .relaunch
        p.heldBecause = "its stop timed out (stop after relaunch)"
        try RecordingSentinel.writePending([p], directory: h.tmp)
        let hung = HungStep("transcript: chunk files")
        defer { hung.release() }
        h.coordinator.folderReads = FolderReads(label: "rc-h-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        h.coordinator.folderReadDeadline = .milliseconds(300)
        await h.coordinator.retryPendingSessions()   // the first attempt: its folder does not answer
        #expect(RecordingSentinel.readPending(directory: h.tmp).map(\.sessionKey) == [p.sessionKey], "kept")
        hung.release()
        h.coordinator.folderReads = FolderReads(label: "rc-h-\(UUID().uuidString)")
        h.coordinator.folderReadDeadline = .seconds(5)
        await h.coordinator.retryPendingSessions()   // the second: finished
        #expect(RecordingSentinel.readPending(directory: h.tmp).isEmpty, "finished")
        let said = h.client.everyRecordedEvent.filter { $0.kind == .streamStopError && $0.detail["held"] != nil }
        #expect(said.count == 1, "\(said.map(\.detail))")
    }

    /// L review 268: a recording root of `/` derives its folders with their leading slash — so a folder on a share mounted
    /// under it is read on the SHARE's queue, never the boot volume's.
    @Test func aRootOfSlashKeepsItsFoldersLeadingSlash() {
        let path = FolderReads.derivedPath(of: "/Volumes/NAS/rec", root: "/", canonicalRoot: "/")
        #expect(path == "/Volumes/NAS/rec")
        let mounts = [FolderReads.Mount(path: "/", isLocal: true), FolderReads.Mount(path: "/Volumes/NAS", isLocal: false)]
        #expect(FolderReads.lexicalVolume(of: path, mounts: mounts, caseInsensitive: false) == "/Volumes/NAS")
        #expect(FolderReads.derivedPath(of: "/", root: "/", canonicalRoot: "/") == "/")
        #expect(FolderReads.derivedPath(of: "/Users/x/rec/2026", root: "/Users/x/rec", canonicalRoot: "/Volumes/Data/rec") == "/Volumes/Data/rec/2026")
        #expect(FolderReads.derivedPath(of: "/Users/x/rec", root: "/Users/x/rec", canonicalRoot: "/") == "/", "a root that resolves to /")
    }
}
