import Foundation
import Testing
@testable import TranscriberCore

// Stream L, round E (items 186–218): the coordinator's side. The fake client and the harness are
// RecordingCoordinatorTests.swift's; `HungRead` is RecordingCoordinatorRoundCTests.swift's.

// MARK: - Evidence: held helpers, commits, waiting rows (198, 200, 201, 205)

@MainActor
@Suite struct RecordingCoordinatorEvidenceRoundETests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }
    private func pending(_ h: Harness) -> [RecordingSentinel] { RecordingSentinel.readPending(directory: h.tmp) }
    private func outDir(_ s: RecordingSentinel) -> URL { URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent() }

    /// A pending session in `folder` with one transcribed chunk: its salvage writes a transcript.
    private func pendingSession(_ h: Harness, _ name: String, in folder: String? = nil) throws -> RecordingSentinel {
        let dir = h.tmp.appendingPathComponent(folder ?? name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: name, meetingStart: Date(), chunkIndices: [0])
        return RecordingSentinel(startedAt: Date(), sessionName: name, systemAudioPath: dir.appendingPathComponent("\(name)-0.wav").path,
                                 micAudioPath: dir.appendingPathComponent("\(name)-0_mic.wav").path, segment: 1, chunkIndex: 0, stopping: true)
    }

    /// L review 198, CRITICAL: while the helper still holds a held session's capture, NOTHING drains it — not the adopt,
    /// not the record's build, not a start — so its events and its `captureStop` never land in another session's record.
    /// Through the stop-ERROR path: the helper answers (it is connected, and a drain would reach it), yet will not let go.
    @Test func aHeldPeriodSalvageNeverDrainsTheHeldHelper() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let older = try pendingSession(h, "old", in: "other")
        try RecordingSentinel.writePending([older], directory: h.tmp)
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID(); s.stopping = true
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.isCapturingResult = true
        h.client.stopError = HelperReplyError(reply: "the writer could not be closed")   // answered — and still holding on
        await h.coordinator.recoverAtLaunch()
        #expect(pending(h).map(\.sessionKey) == [s.sessionKey], "held")
        #expect(h.presented.value.map(\.lastPathComponent) == ["old.json"], "the other one is finished")
        #expect(h.client.drains.isEmpty, "never drained while it holds on: \(h.client.drains)")
        #expect(!h.client.evidenceOrder.contains { $0.hasPrefix("attribute:") }, "\(h.client.evidenceOrder)")
    }

    /// L review 200: a session found already transcribed commits its evidence only once its record is BUILT (without
    /// draining): the live log may be the only copy of an anomaly the crashed process never wrote out.
    @Test func anAlreadyTranscribedSessionBuildsItsRecordBeforeTheCommit() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let p = try pendingSession(h, "p")
        let dir = outDir(p)
        _ = try #require(try await ChunkedSessionRecovery.recover(outputDirectory: dir, sessionId: "p", config: h.config.config,
                                                                   transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: h.runner))
        do {   // the crashed process: an anomaly in its live log, and no record written
            let recorder = SessionEvidence()
            recorder.beginCapture(sessionId: "p", directory: dir)
            recorder.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
        }
        LiveDiagnosticsLog.flushAll()
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.client.realEvidence = SessionEvidence(folderReads: FolderReads(label: "rc-e-\(UUID().uuidString)"))
        await h.coordinator.retryPendingSessions()
        LiveDiagnosticsLog.flushAll()
        #expect(h.presented.value.isEmpty, "nothing transcribed again")
        #expect(h.client.drains.isEmpty, "built without draining: \(h.client.drains)")
        let record = try String(contentsOf: dir.appendingPathComponent("p.diag.jsonl"), encoding: .utf8)
        #expect(record.contains("xpcInterruption"), "the record was written before the live log went")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("p.diag.live.jsonl").path))
    }

    /// L review 201: a pass that skips its salvages because the helper's drain did not answer says so — a row, never
    /// silence while the recordings wait.
    @Test func aPassWaitingOnAnUnansweredDrainSaysSo() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        try RecordingSentinel.writePending([try pendingSession(h, "p")], directory: h.tmp)
        h.client.attributionAnswers = false
        await h.coordinator.retryPendingSessions()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("waiting to finish 1 earlier recording"), "\(row)")
    }

    /// L review 205, the legacy single-file site: the Stop's fallback commits the evidence only AFTER its transcript is on
    /// disk (the positive pin beside `theLegacyStopCommitsNothingWithoutATranscript`).
    @Test func theLegacyStopCommitsAfterItsTranscript() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.isCapturingResult = true
        h.runner.failSetupForTesting = true   // re-attached without a pipeline
        await h.coordinator.recoverAtLaunch()
        // Not a chunk of any session (no `-N`), and no session.json: the legacy single-file run.
        let sys = outDir(s).appendingPathComponent("older.wav"), mic = outDir(s).appendingPathComponent("older_mic.wav")
        try Harness.headerOnlyWAV().write(to: sys); try Harness.headerOnlyWAV().write(to: mic)
        h.client.stopResult = AudioPaths(systemAudio: sys, micAudio: mic)
        let transcriptThere = Harness.Box(false)
        h.client.onCommit = { id, dir in transcriptThere.value = FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).json").path) }
        await h.coordinator.stopRecording()
        #expect(h.client.commitCalls == ["older"] && transcriptThere.value, "\(h.client.commitCalls)")
    }
}
