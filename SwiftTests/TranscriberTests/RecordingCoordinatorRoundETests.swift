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

// MARK: - The Stop: held, bounded, honest (186–189, 197, 211, 218)

@MainActor
@Suite struct RecordingCoordinatorStopRoundETests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }
    private func pending(_ h: Harness) -> [RecordingSentinel] { RecordingSentinel.readPending(directory: h.tmp) }
    private func outDir(_ s: RecordingSentinel) -> URL { URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent() }
    private func recording(_ h: Harness) async throws -> FakeCaptureClient.StartCall {
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "mic-1")
        return try #require(h.client.startCalls.first)
    }
    /// A re-attached recording without a chunk pipeline, one transcribed chunk in its session.json: its Stop takes the
    /// fallback (a rebuild from disk).
    private func reattachedWithoutPipeline(_ h: Harness) async throws -> RecordingSentinel {
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        h.client.isCapturingResult = true
        h.runner.failSetupForTesting = true
        await h.coordinator.recoverAtLaunch()
        #expect(h.appState.isRecording && h.runner.chunkProcessor == nil)
        h.client.stopResult = AudioPaths(systemAudio: outDir(s).appendingPathComponent("sess-1.wav"),
                                         micAudio: outDir(s).appendingPathComponent("sess-1_mic.wav"))
        return s
    }

    /// L review 186: the user's Stop HELD because another stop was still under way carries the user's own cause — never
    /// "its capture failed" — and, once the helper lets go, is said for what it was.
    @Test func aHeldUserStopIsSaidAsTheUsersStop() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try await recording(h)
        h.client.stopError = RefusedStoppingError()
        h.coordinator.stopDeadline = .milliseconds(200)
        h.coordinator.stopReaskInterval = .milliseconds(50)
        h.coordinator.stopReaskMinimumBudget = .milliseconds(10)
        await h.coordinator.stopRecording()
        let kept = try #require(pending(h).first)
        #expect(kept.stopCause == .stopInterrupted && kept.heldReason == .stopUnderWay, "\(String(describing: kept.stopCause))")
        h.appState.acknowledge(.recordingStopped)
        h.client.stopError = nil   // the other stop is over
        await h.coordinator.retryPendingSessions()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("you stopped it while another stop was still under way") && !row.contains("capture failed"), "\(row)")
    }

    /// L review 187: a re-ask needs a minimum of the Stop's budget: a refusal slower than what is left holds the session
    /// without asking again — never a sliver-of-budget re-ask that times out, drops the connection and re-ingests while the
    /// other stop may still be writing.
    @Test func aRefusalSlowerThanTheLeftoverBudgetHoldsWithoutDroppingTheHelper() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try await recording(h)
        h.client.stopError = RefusedStoppingError()
        h.client.onStop = { try? await Task.sleep(for: .milliseconds(150)) }   // each refusal takes 150 ms
        h.coordinator.stopDeadline = .milliseconds(400)
        h.coordinator.stopReaskInterval = .milliseconds(20)
        h.coordinator.stopReaskMinimumBudget = .milliseconds(150)
        await h.coordinator.stopRecording()
        #expect(h.client.droppedConnections == 0, "never dropped while another stop may still be writing")
        #expect(pending(h).first?.heldReason == .stopUnderWay && h.client.finalizeCalls.isEmpty, "held, nothing finalized")
        #expect(h.recordingMic.current == .some("mic-1"))
    }

    /// … and a re-ask that times out AFTER a refusal was seen is the other stop still under way: held, never dropped.
    @Test func aTimeoutAfterARefusalHolds() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try await recording(h)
        let client = h.client
        client.stopError = RefusedStoppingError()
        client.onStop = { if client.stopCalls >= 2 { try? await Task.sleep(for: .seconds(1)) } }   // the re-ask never answers
        h.coordinator.stopDeadline = .milliseconds(400)
        h.coordinator.stopReaskInterval = .milliseconds(20)
        h.coordinator.stopReaskMinimumBudget = .milliseconds(100)
        await h.coordinator.stopRecording()
        #expect(h.client.stopCalls == 2 && h.client.droppedConnections == 0, "\(h.client.stopCalls) \(h.client.droppedConnections)")
        #expect(pending(h).first?.heldReason == .stopUnderWay && h.client.finalizeCalls.isEmpty)
    }

    /// L review 188: a held Stop whose recovery file is gone is still KEPT — from where the live pipeline says the session
    /// is, with its mic — so the promise "Parley will finish it" holds, and the mic is released once the helper lets go.
    @Test func aHeldStopWithoutARecoveryFileIsStillKeptWithItsMic() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let call = try await recording(h)
        RecordingSentinel.delete(directory: h.tmp)   // the recovery file is gone
        h.client.stopError = RefusedStoppingError()
        h.coordinator.stopDeadline = .milliseconds(200)
        h.coordinator.stopReaskInterval = .milliseconds(50)
        h.coordinator.stopReaskMinimumBudget = .milliseconds(10)
        await h.coordinator.stopRecording()
        let kept = try #require(pending(h).first, "kept, as promised")
        #expect(kept.sessionKey == call.outputDirectory.appendingPathComponent(call.sessionId).path)
        #expect(kept.micDeviceUID == "mic-1" && kept.heldReason == .stopUnderWay && kept.stopping)
        #expect(h.recordingMic.current == .some("mic-1"), "marked while the helper may hold it")
        h.client.stopError = nil   // the helper lets go
        await h.coordinator.retryPendingSessions()
        #expect(h.recordingMic.current == .none && pending(h).isEmpty, "released, and finished")
    }

    /// L review 189: the Stop's critical body puts the helper's reply in words — never its wire text.
    @Test func aStopFailureNeverShowsTheHelpersWireText() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try await reattachedWithoutPipeline(h)
        h.client.stopError = NoCaptureError()
        await h.coordinator.stopRecording()
        let body = try #require(h.criticals.value.last?.body)
        #expect(!body.contains(CaptureReplies.noCaptureInProgress) && body.contains("the capture had already stopped"), "\(body)")
    }

    /// … and so does a failed crash restart.
    @Test func aFailedRestartNeverShowsTheHelpersWireText() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let call = try await recording(h)
        try FileManager.default.createDirectory(at: call.outputDirectory, withIntermediateDirectories: true)
        h.client.startError = HelperReplyError(reply: CaptureReplies.startTimedOut)
        await h.coordinator.handleXPCCrash()
        let said = (h.appState.criticalError ?? "") + h.criticals.value.map(\.body).joined()
        #expect(!said.contains(CaptureReplies.startTimedOut) && said.contains("the audio system didn’t respond"), "\(said)")
    }

    /// L review 211: a Stop with no pipeline whose rebuild's folder stops answering KEEPS the session — never a second
    /// look under another key that answers, calls it failed and forgets it.
    @Test func aNoPipelineStopWhoseFolderStopsAnsweringKeepsTheSession() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try await reattachedWithoutPipeline(h)
        // The rebuild's look answers too late; a look after it answers at once.
        h.coordinator.folderReads = FolderReads(label: "rc-e-\(UUID().uuidString)", beforeEachRead: { name in
            if name == "recovery: session folder" { Thread.sleep(forTimeInterval: 0.3) }
        })
        h.coordinator.folderReadDeadline = .milliseconds(200)
        h.coordinator.folderPrepareDeadline = .milliseconds(200)
        await h.coordinator.stopRecording()
        let kept = try #require(pending(h).first, "kept")
        #expect(kept.sessionKey == s.sessionKey && kept.stopCause == .folderNotAnswering)
        #expect(h.criticals.value.last?.body.contains("isn’t answering") == true, "\(h.criticals.value)")
    }

    /// L review 218 (as 178): a Stop with no pipeline whose transcription engine cannot be made keeps the session PENDING,
    /// says so, and finishes it once the engine is ready — never "could not be transcribed" and forgotten. With audio to
    /// recognise: the chunk the Stop sealed (L review 232 — with none, no engine is needed).
    @Test func aNoPipelineStopWhoseEngineCannotBeMadeKeepsTheSession() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try await reattachedWithoutPipeline(h)
        try RecoveryFixtures.writeFakeWav(at: outDir(s).appendingPathComponent("sess-1.wav"), seconds: 1)
        h.engineError.value = TranscriptionRunner.RunnerError.engineUnavailable("SpeechAnalyzer")
        await h.coordinator.stopRecording()
        #expect(pending(h).map(\.sessionKey) == [s.sessionKey], "kept, never forgotten")
        #expect(h.presented.value.isEmpty && h.appState.isIdle)
        #expect(h.recordingMic.current == .none, "the helper let go of the mic")
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("transcription engine isn’t ready") && !row.contains("could not be transcribed"), "\(row)")
        h.engineError.value = nil   // Setup finished, a model download, a Settings save
        await h.coordinator.transcriptionEngineMayBeReady()
        #expect(pending(h).isEmpty && h.presented.value.map(\.lastPathComponent) == ["sess.json"])
    }

    /// L review 195: an exit whose live-log flush ran out of its bound says so, so the app's last flush
    /// (`applicationWillTerminate`) is skipped — never a second wait past the termination's bound.
    @Test func anExitFlushThatRanOutIsSaid() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try await recording(h)
        h.client.onFlush = { try? await Task.sleep(for: .seconds(3)) }
        h.coordinator.evidenceFlushBound = .milliseconds(200)
        await h.coordinator.prepareForTermination(bound: .seconds(2))
        #expect(h.coordinator.exitFlushTimedOut)
        let quick = try Harness()
        defer { tearDown(quick) }
        _ = try await recording(quick)
        await quick.coordinator.prepareForTermination(bound: .seconds(2))
        #expect(!quick.coordinator.exitFlushTimedOut, "a flush that finished")
    }
}

// MARK: - Honest outcomes: rebuilds, causes, resumes, lists (190–194, 196, 197)

@MainActor
@Suite struct RecordingCoordinatorOutcomeRoundETests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }
    private func pending(_ h: Harness) -> [RecordingSentinel] { RecordingSentinel.readPending(directory: h.tmp) }
    private func outDir(_ s: RecordingSentinel) -> URL { URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent() }

    /// A FINALIZED session in another boot's slot: `transcript` damaged (unreadable) or missing, its progress file kept or not.
    private func finalized(_ h: Harness, keepProgress: Bool, transcript: (URL) throws -> Void) async throws -> RecordingSentinel {
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-3600); s.bootSessionUUID = "another-boot"
        try RecordingSentinel.write(s, directory: h.tmp)
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        let result = try #require(try await ChunkedSessionRecovery.recover(outputDirectory: outDir(s), sessionId: "sess", config: h.config.config,
                                                                            transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: h.runner))
        if keepProgress { try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0]) }
        try transcript(result.jsonPath)
        return s
    }

    /// L review 190: a rebuild names the damaged copy only when the listing FOUND one — here the listing did not answer.
    @Test func aRebuildNamesNoDamagedCopyItNeverSaw() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try await finalized(h, keepProgress: true) { try Data("{ damaged".utf8).write(to: $0) }
        let hung = HungRead("salvage: transcript")
        defer { hung.release() }
        h.coordinator.folderReads = FolderReads(label: "rc-e-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        h.coordinator.folderReadDeadline = .milliseconds(150)
        await h.coordinator.recoverAtLaunch()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("REBUILT") && !row.contains("damaged copy is kept"), "\(row)")
    }

    /// … a MISSING transcript (a finalized marker, no transcript) is said as missing — rebuilt, with no damaged copy named …
    @Test func aMissingTranscriptIsRebuiltAndSaidMissing() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try await finalized(h, keepProgress: true) { try FileManager.default.removeItem(at: $0) }
        await h.coordinator.recoverAtLaunch()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("was missing, so it was REBUILT") && !row.contains("damaged"), "\(row)")
    }

    /// … and with nothing to rebuild it from, a missing transcript is never "kept as it is".
    @Test func aMissingTranscriptWithNothingToRebuildFromIsNeverSaidKept() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try await finalized(h, keepProgress: false) { try FileManager.default.removeItem(at: $0) }
        try Harness.headerOnlyWAV().write(to: outDir(s).appendingPathComponent("sess-0.wav"))   // its audio, on disk
        await h.coordinator.recoverAtLaunch()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("is missing") && !row.contains("kept as it is"), "\(row)")
        #expect(row.contains("Its audio (1 chunk) is kept on disk"), "\(row)")
    }

    /// L review 192: a resume clears the stale cause and quit marks it carries — the live recording has none.
    @Test func aResumeCarriesNoStaleCauseIntoTheLiveRecording() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID()
        s.stopCause = .folderNotAnswering; s.quitDuringFinalize = true; s.quitMarkedByPowerOff = true
        s.heldReason = .relaunch; s.heldBecause = "its stop timed out"; s.salvageBegan = true
        try RecordingSentinel.write(s, directory: h.tmp)
        await h.coordinator.recoverAtLaunch()
        #expect(h.appState.isRecording, "resumed")
        let live = try #require(RecordingSentinel.read(directory: h.tmp))
        #expect(live.stopCause == nil && !live.quitDuringFinalize && !live.quitMarkedByPowerOff && !live.stopping)
        // … nor a hold, nor a salvage's start (L review 250).
        #expect(live.heldReason == nil && live.heldBecause == nil && !live.salvageBegan)
    }

    /// L review 193: a start that failed is said as never started — "could not be started", never "restarted".
    @Test func aFailedStartIsSaidAsNeverStarted() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        h.client.startError = CaptureCallTimeout(call: "start", seconds: 15)
        h.coordinator.helperStopDeadline = .milliseconds(100)
        h.client.onStop = { try? await Task.sleep(for: .seconds(1)) }   // the helper will not let go: HELD
        await h.coordinator.startRecording(sessionName: "held", microphoneDeviceId: nil)
        let held = try #require(pending(h).first)
        #expect(held.stopCause == .startFailed && held.heldReason == .startFailed, "\(String(describing: held.stopCause))")
        let outcome = SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0)
        for row in [RecoveryMessages.heldStopped(at: Date(), outcome: outcome, held: .startFailed, cause: .startFailed),
                    RecoveryMessages.relaunchStopped(at: Date(), outcome: outcome, cause: .startFailed)] {
            #expect(row.contains("could not be started") && !row.contains("restarted"), "\(row)")
        }
    }

    /// L review 194: a Quit during a launch salvage keeps the cause the salvage first saw — stamped on the slot too — and
    /// the next launch says both: "Parley was quit while recovering it", after the crash, never only "quit".
    @Test func aQuitDuringALaunchSalvageKeepsItsFirstCause() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-3600); s.bootSessionUUID = BootSession.currentUUID(); s.stopping = true
        try RecordingSentinel.write(s, directory: h.tmp)   // the user's Stop, then a crash while its transcript was written
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        let inBuild = Harness.Box(false), release = Harness.Box(false)
        h.client.onFinalizeDiagnostics = {
            inBuild.value = true
            while !release.value { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let coordinator = h.coordinator
        let relaunch = Task { await coordinator.recoverAtLaunch() }
        await Harness.until { inBuild.value }
        #expect(await coordinator.prepareForQuit(confirm: { true }))   // the Quit, during the salvage
        let slot = try #require(RecordingSentinel.read(directory: h.tmp))
        #expect(slot.quitDuringFinalize && slot.stopCause == .appCrash, "the first cause stands beside the quit")
        // The next launch (the process ended during the salvage): it says both.
        let next = try Harness()
        defer { tearDown(next) }
        try RecordingSentinel.write(slot, directory: next.tmp)
        await next.coordinator.recoverAtLaunch()
        release.value = true
        await relaunch.value
        let row = try #require(next.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("quit while recovering") && row.contains("Parley crashed"), "\(row)")
    }

    /// L review 196: an unreadable `pending-<uuid>.json` beside the main list is said in a row — never only a log line.
    @Test func anUnreadableOverflowListIsSaid() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let dir = h.tmp.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try RecordingSentinel.writePending([RecordingSentinel(startedAt: Date(), sessionName: "p", systemAudioPath: dir.appendingPathComponent("p-0.wav").path,
                                                              micAudioPath: dir.appendingPathComponent("p-0_mic.wav").path, stopping: true)],
                                           directory: h.tmp)
        try Data("not a list".utf8).write(to: h.tmp.appendingPathComponent("pending-\(UUID().uuidString).json"))
        await h.coordinator.retryPendingSessions()
        // Its own row, never "Recording STOPPED" (L review 249).
        let row = try #require(h.appState.activeAlarms[.pendingListUnreadable]?.message)
        #expect(row.contains("could not read") && row.contains("pending-"), "\(row)")
    }

    /// L review 197: a finalized session is never finalized again over its transcript — even when a gate upstream could
    /// not look (a re-attach whose scan did not answer): the transcript and its renames are kept.
    @Test func aFinalizedSessionIsNeverFinalizedAgainOverItsTranscript() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let dir = h.tmp.appendingPathComponent("f")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "f", meetingStart: Date(), chunkIndices: [0])
        let state = try #require(SessionState.read(directory: dir, sessionId: "f"))
        let first = try await h.runner.finalize(sessionState: state, outputDirectory: dir, config: h.config.config)
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: first.jsonPath)) as? [String: Any])
        json["renamed_by_the_user"] = true
        try TranscriptAssembler.write(json, to: first.jsonPath)
        let renamed = try Data(contentsOf: first.jsonPath)
        await #expect(throws: SessionAlreadyFinalized.self) {
            _ = try await h.runner.finalize(sessionState: state, outputDirectory: dir, config: h.config.config)
        }
        #expect(try Data(contentsOf: first.jsonPath) == renamed, "never written over")
    }
}

// MARK: - Wording (186, 191)

@Suite struct RecoveryMessagesRoundETests {
    /// L review 191: every sentence that names a recovered transcript honours `recognitionChecked` — the quit's, and the
    /// REBUILT one — never implying its words were checked.
    @Test func anUncheckedRecoveryIsNeverImpliedTranscribedInAnyWording() {
        let url = URL(fileURLWithPath: "/r/m.json")
        let unchecked = SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 2, recognitionChecked: false)
        let quit = RecoveryMessages.quitWhileFinishing(outcome: unchecked)
        #expect(quit.contains("could not read it back to check"), "\(quit)")
        let rebuilt = SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 2, recognitionChecked: false, rebuiltKeeping: "m.damaged.json")
        let sentence = RecoveryMessages.outcomeSentence(rebuilt)
        #expect(sentence.contains("REBUILT") && sentence.contains("to check"), "\(sentence)")
    }

    /// L review 186: the user's own Stop, held while another stop ran, is worded as such.
    @Test func aStopInterruptedIsTheUsersStop() {
        let outcome = SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0)
        for row in [RecoveryMessages.relaunchStopped(at: Date(), outcome: outcome, cause: .stopInterrupted),
                    RecoveryMessages.heldStopped(at: Date(), outcome: outcome, held: .stopUnderWay, cause: .stopInterrupted)] {
            #expect(row.contains("you stopped it while another stop was still under way") && !row.contains("capture failed"), "\(row)")
        }
    }
}

// MARK: - The rotator at a Stop (208, 213)

@MainActor
@Suite struct RecordingCoordinatorRotationRoundETests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }

    /// L review 208: a Stop during a rotation whose look at its folder has not answered never lets that rotation send its
    /// rotate: the stopped rotator checks after the look, and the Stop's wait covers the look.
    @Test func aStopDuringAHungLookSendsNoRotate() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let rotator = try #require(h.runner.chunkRotator)
        let hung = HungRead("rotation: chunk files")
        defer { hung.release() }
        rotator.folderReads = FolderReads(label: "rc-e-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        rotator.folderProbeSeconds = 0.3
        rotator.rotateNow()
        await Harness.until { hung.reached }
        await h.coordinator.stopRecording()
        #expect(h.client.rotateCalls == 0, "a stopped rotator never sends the rotate it was looking for")
        #expect(h.appState.isIdle)
    }

    /// L review 213, the coordinator's side: late chunks the Stop could not check are on record and said in a row naming
    /// their files — and a look that did not answer is recorded as the folder not answering (L review 216: the wiring).
    @Test func lateChunksTheStopCouldNotCheckAreSaidInARow() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let call = try #require(h.client.startCalls.first)
        let rotator = try #require(h.runner.chunkRotator)
        h.client.rotateError = CaptureCallTimeout(call: "rotateChunk", seconds: 10)
        await rotator.rotateForTesting()   // chunk 1 asked for: timed out
        await rotator.rotateForTesting()   // chunk 2 asked for: timed out
        let hung = HungRead("rotation: chunk files")
        defer { hung.release() }
        rotator.folderReads = FolderReads(label: "rc-e-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        rotator.folderProbeSeconds = 0.2
        // The helper's stop reply names chunk 2: the rotation to it completed after all.
        h.client.stopResult = AudioPaths(systemAudio: call.outputDirectory.appendingPathComponent("\(call.sessionId)-2.wav"),
                                         micAudio: call.outputDirectory.appendingPathComponent("\(call.sessionId)-2_mic.wav"))
        await h.coordinator.stopRecording()
        #expect(h.client.everyRecordedEvent.contains { $0.kind == .folderNotAnswering && $0.detail["unchecked_chunks"] == "1" })
        #expect(h.client.everyRecordedEvent.contains { $0.kind == .folderNotAnswering && $0.detail["during"] == "stop" })
        // Its own row, never under "Recording STOPPED" (L review 241: 219's kind), in the singular for one chunk.
        #expect(h.appState.activeAlarms[.recordingStopped] == nil)
        let row = try #require(h.appState.activeAlarms[.audioAfterTranscript]?.message)
        #expect(row.contains("\(call.sessionId)-1.wav") && row.contains("not transcribed"), "\(row)")
        #expect(row.contains("If it is in") && !row.contains("they"), "\(row)")
    }
}

// MARK: - Folder reads: joined, bounded, honest (209, 210, 215, 216)

@MainActor
@Suite struct RecordingCoordinatorFolderReadsRoundETests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }
    private func pending(_ h: Harness) -> [RecordingSentinel] { RecordingSentinel.readPending(directory: h.tmp) }

    /// L review 210: a Start during a slow read of the SAME folder — a wake's pending retry reading it — waits for that
    /// read's answer within its own bound, and starts: "no answer yet" is never "not reachable".
    @Test func aStartDuringASlowRetryReadOfItsFolderWaitsForItsAnswer() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let rec = h.tmp.appendingPathComponent("rec")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        h.config.update { $0.recordingDirectory = rec.path }
        try RecordingSentinel.writePending([RecordingSentinel(startedAt: Date(), sessionName: "p", systemAudioPath: rec.appendingPathComponent("p-0.wav").path,
                                                              micAudioPath: rec.appendingPathComponent("p-0_mic.wav").path, stopping: true)],
                                           directory: h.tmp)
        let slow = Harness.Box(false)
        h.coordinator.folderReads = FolderReads(label: "rc-e-\(UUID().uuidString)", beforeEachRead: { name in
            guard name == "pending folder" else { return }
            slow.value = true
            Thread.sleep(forTimeInterval: 0.3)   // slow, and answering
        })
        let coordinator = h.coordinator
        let retry = Task { await coordinator.retryPendingSessions() }   // the wake's retry
        await Harness.until { slow.value }
        await coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(h.appState.isRecording, "\(String(describing: h.appState.errorMessage))")
        await retry.value
    }

    /// … and only the Start's own bound running out is "not answering" — said as such, never "not reachable".
    @Test func aStartWhoseFolderDoesNotAnswerSaysSo() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        let hung = HungRead("start: recording folder")
        defer { hung.release() }
        h.coordinator.folderReads = FolderReads(label: "rc-e-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        h.coordinator.folderReadDeadline = .milliseconds(200)
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let said = try #require(h.appState.errorMessage)
        #expect(said.contains("isn’t answering") && !said.contains("reach"), "\(said)")
    }

    /// L review 215: the rebuild's composite look — its sweeps and moves, its reads — has a longer bound than a single read:
    /// a slow but healthy share is finished, never "not answering".
    @Test func aSlowButAnsweringRebuildIsFinished() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let dir = h.tmp.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "p", meetingStart: Date(), chunkIndices: [0])
        try RecordingSentinel.writePending([RecordingSentinel(startedAt: Date(), sessionName: "p", systemAudioPath: dir.appendingPathComponent("p-0.wav").path,
                                                              micAudioPath: dir.appendingPathComponent("p-0_mic.wav").path, stopping: true)],
                                           directory: h.tmp)
        h.coordinator.folderReads = FolderReads(label: "rc-e-\(UUID().uuidString)", beforeEachRead: { name in
            if name == "recovery: session folder" { Thread.sleep(forTimeInterval: 0.4) }
        })
        h.coordinator.folderReadDeadline = .milliseconds(200)
        h.coordinator.folderPrepareDeadline = .seconds(2)
        await h.coordinator.retryPendingSessions()
        #expect(h.presented.value.map(\.lastPathComponent) == ["p.json"] && pending(h).isEmpty, "finished")
        #expect(h.appState.activeAlarms[.recordingFolderUnavailable] == nil, "never \"not answering\"")
    }

    /// L review 216: the rotator reads its folder through the coordinator's reader, and a look that does not answer is on
    /// record as the folder not answering — the recording goes on.
    @Test func theRotatorsLooksGoThroughTheCoordinatorsReader() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        let hung = HungRead("rotation: chunk files")
        defer { hung.release() }
        h.coordinator.folderReads = FolderReads(label: "rc-e-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let rotator = try #require(h.runner.chunkRotator)
        #expect(rotator.folderReads === h.coordinator.folderReads, "the coordinator's reader")
        rotator.folderProbeSeconds = 0.2
        await rotator.rotateForTesting()
        #expect(hung.reached && h.client.rotateCalls == 1 && h.appState.isRecording, "never blocked: rotated by the counter")
        #expect(h.client.recordedEvents.contains { $0.kind == .folderNotAnswering && $0.detail["during"] == "rotation" })
    }
}

// MARK: - The transcript's looks and writes (215, 216)

@MainActor
@Suite struct TranscriptionRunnerReadsRoundETests {
    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("runner-e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// L review 215: the leftover WAVs' deletes run after the looks, never inside a bounded read — a slow delete on a healthy
    /// share never makes the transcript "not answering". They still run — with the merge ON, the default (L review 240): the
    /// merge deletes the archives first, and the leftovers found beside them are deleted all the same.
    @Test func slowLeftoverDeletesNeverMakeTheFolderNotAnswering() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let start = Date().addingTimeInterval(-60)
        let processor = ChunkProcessor(config: .default, outputDirectory: d,
            sessionState: SessionState(sessionId: "f", meetingStart: start, engine: "fluid_audio", chunkDurationMinutes: 1),
            transcriber: FakeEngine(), diarizer: FakeDiarizer())
        for i in 0...1 {   // two chunks, archived: the merge runs
            try RecoveryFixtures.writeFakeWav(at: d.appendingPathComponent("f-\(i).wav"), seconds: 1)
            await processor.processLastChunk(ChunkRotator.FinalizedChunk(index: i, systemPath: d.appendingPathComponent("f-\(i).wav").path,
                                                                         micPath: d.appendingPathComponent("f-\(i)_mic.wav").path,
                                                                         startTime: start.addingTimeInterval(Double(i))))
        }
        let state = await processor.getSessionState()
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("f-0.m4a").path))
        try Harness.headerOnlyWAV().write(to: d.appendingPathComponent("f-0.wav"))   // a leftover beside its archive
        let runner = TranscriptionRunner()
        runner.folderReads = FolderReads(label: "runner-e-\(UUID().uuidString)")
        runner.folderReadSeconds = 0.2
        let removed = Harness.Box(false)
        runner.leftoverRemoval = { wavs in
            Thread.sleep(forTimeInterval: 0.4)   // a slow share
            TranscriptionRunner.removeLeftoverWAVs(wavs)
            removed.value = true
        }
        let result = try await runner.finalize(sessionState: state, outputDirectory: d, config: .default)
        #expect(FileManager.default.fileExists(atPath: result.jsonPath.path), "written, never \"not answering\"")
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("f.m4a").path), "merged")
        await Harness.until { removed.value }
        #expect(removed.value && !FileManager.default.fileExists(atPath: d.appendingPathComponent("f-0.wav").path), "the leftover still goes")
    }

    /// L review 216 (pinned): `run`'s look at the microphone file is bounded — a folder that does not answer throws, never
    /// a transcript written blind.
    @Test func theLegacyRunsMicLookIsBounded() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let sys = d.appendingPathComponent("older.wav"), mic = d.appendingPathComponent("older_mic.wav")
        try Harness.headerOnlyWAV().write(to: sys); try Harness.headerOnlyWAV().write(to: mic)
        let hung = HungRead("transcript: mic file")
        defer { hung.release() }
        let runner = TranscriptionRunner()
        runner.folderReads = FolderReads(label: "runner-e-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        runner.folderReadSeconds = 0.2
        await #expect(throws: FolderNotAnswering.self) {
            _ = try await runner.run(systemAudio: sys, micAudio: mic, outputDirectory: d, config: .default)
        }
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("older.json").path))
    }
}

// MARK: - The main actor never waits on the recovery file, nor on a legacy transcript's folder (217)

@MainActor
@Suite struct RecordingCoordinatorMainActorIORoundETests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }

    /// A recovery-file queue whose operation named `label` hangs for up to a second, once.
    private func hanging(_ label: String) -> (io: SentinelIO, gate: DispatchSemaphore, reached: Harness.Box<Bool>) {
        let gate = DispatchSemaphore(value: 0), reached = Harness.Box(false)
        let io = SentinelIO(label: "rc-e-sentinel-\(UUID().uuidString)", beforeEach: { name in
            guard name == label, !reached.value else { return }
            reached.value = true
            _ = gate.wait(timeout: .now() + 1)   // the watchdog
        })
        return (io, gate, reached)
    }

    /// A main-actor ticker: ten 10 ms sleeps, and how long they took.
    private func ticker() -> Task<Duration, Never> {
        Task { @MainActor in
            let began = ContinuousClock.now
            for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(10)) }
            return ContinuousClock.now - began
        }
    }

    /// L review 217: the start's write of the recovery file runs off the main actor — a slow Application Support folder
    /// never freezes the UI.
    @Test func theStartsRecoveryFileWriteRunsOffTheMainActor() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        let (io, gate, reached) = hanging("start: write")
        h.coordinator.sentinelIO = io
        let coordinator = h.coordinator
        let ticks = ticker()
        let starting = Task { await coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil) }
        #expect(await ticks.value < .milliseconds(500), "the UI stays responsive")
        #expect(reached.value)
        gate.signal()
        await starting.value
        #expect(h.appState.isRecording && RecordingSentinel.read(directory: h.tmp) != nil)
    }

    /// … and so do the Stop's read, mark and delete of it.
    @Test func theStopsRecoveryFileIORunsOffTheMainActor() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let (io, gate, reached) = hanging("stop: read")
        h.coordinator.sentinelIO = io
        let coordinator = h.coordinator
        let ticks = ticker()
        let stopping = Task { await coordinator.stopRecording() }
        #expect(await ticks.value < .milliseconds(500), "the UI stays responsive")
        #expect(reached.value)
        gate.signal()
        await stopping.value
        #expect(h.appState.isIdle)
    }

    /// … and a crash recovery's read of it.
    @Test func aCrashRecoverysRecoveryFileReadRunsOffTheMainActor() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let (io, gate, reached) = hanging("crash: read")
        h.coordinator.sentinelIO = io
        let coordinator = h.coordinator
        let ticks = ticker()
        let recovering = Task { await coordinator.handleXPCCrash() }
        #expect(await ticks.value < .milliseconds(500), "the UI stays responsive")
        #expect(reached.value)
        gate.signal()
        await recovering.value
    }

    /// … and every rotation's liveness write: queued, never waited for.
    @Test func aRotationsLivenessWriteNeverBlocksTheMainActor() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let (io, gate, reached) = hanging("liveness")
        h.coordinator.sentinelIO = io
        let rotator = try #require(h.runner.chunkRotator)
        let ticks = ticker()
        let rotating = Task { await rotator.rotateForTesting() }
        #expect(await ticks.value < .milliseconds(500), "the UI stays responsive")
        await rotating.value
        await Harness.until { reached.value }
        #expect(reached.value && h.client.rotateCalls == 1)
        gate.signal()
    }
}

@MainActor
@Suite struct TranscriptionRunnerRunRoundETests {
    /// L review 217: the legacy single-file transcript's discovery, header repair and size reads run on the folder's queue,
    /// bounded — a folder that does not answer throws, never a main actor frozen, never a transcript written blind.
    @Test func theLegacyRunsDiscoveryIsBoundedAndOffTheMainActor() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("runner-e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let sys = d.appendingPathComponent("older.wav"), mic = d.appendingPathComponent("older_mic.wav")
        try Harness.headerOnlyWAV().write(to: sys); try Harness.headerOnlyWAV().write(to: mic)
        let hung = HungRead("transcript: segments")
        defer { hung.release() }
        let runner = TranscriptionRunner()
        runner.folderReads = FolderReads(label: "runner-e-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        runner.folderReadSeconds = 0.2
        runner.folderWriteSeconds = 0.2
        let began = ContinuousClock.now
        await #expect(throws: FolderNotAnswering.self) {
            _ = try await runner.run(systemAudio: sys, micAudio: mic, outputDirectory: d, config: .default)
        }
        #expect(hung.reached && ContinuousClock.now - began < .seconds(2), "bounded, on the folder's queue")
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("older.json").path))
    }
}
