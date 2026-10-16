import Foundation
import Testing
@testable import TranscriberCore

// Stream L, round C (items 139–168): the coordinator's side. The fake client and the harness are
// RecordingCoordinatorTests.swift's.

// MARK: - Folder reads per volume, coalescing (160, 164)

@MainActor
@Suite struct RecordingCoordinatorVolumeTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }

    /// L review 160: a read hung on one volume (a dead share) never makes a Start refuse a HEALTHY folder on another.
    @Test func aHungVolumeNeverRefusesAStartOnAnother() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        let hung = HungStep("dead share")
        defer { hung.release() }
        h.coordinator.folderReads = FolderReads(label: "rc-c-\(UUID().uuidString)",
                                                volumeOf: { $0.hasPrefix("/Volumes/Dead") ? "/Volumes/Dead" : "/" },
                                                beforeEachRead: { hung.hangIfNamed($0) })
        h.coordinator.folderReadDeadline = .milliseconds(300)
        let reads = h.coordinator.folderReads
        let deadRead = Task { await reads.read("dead share", folder: "/Volumes/Dead/rec", seconds: 5) { 0 } }
        await Harness.until { hung.reached }
        await h.coordinator.startRecording(sessionName: "healthy", microphoneDeviceId: nil)
        #expect(h.appState.isRecording && h.client.startCalls.count == 1, "\(String(describing: h.appState.errorMessage))")
        hung.release()
        _ = await deadRead.value
    }

    /// L reviews 164, 210, 216: a pending folder whose earlier read has not answered is waited for, within the retry's own
    /// bound — never "not reachable" on a guess. When the bound runs out, it is said as NOT ANSWERING, and the raised alarm
    /// stays raised while the folder still does not answer. (Renamed in L review 241: it says what it asserts.)
    @Test func aJoinedPendingFolderReadThatRunsOutIsSaidNotAnswering() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let folder = h.tmp.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RecordingSentinel.writePending([RecordingSentinel(startedAt: Date(), sessionName: "p", systemAudioPath: folder.appendingPathComponent("p-0.wav").path,
                                                              micAudioPath: folder.appendingPathComponent("p-0_mic.wav").path, stopping: true)],
                                           directory: h.tmp)
        let hung = HungStep("earlier read")
        defer { hung.release() }
        h.coordinator.folderReads = FolderReads(label: "rc-c-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        let reads = h.coordinator.folderReads
        let earlier = Task { await reads.read("earlier read", folder: folder.path, seconds: 5) { 0 } }
        await Harness.until { hung.reached }
        h.coordinator.folderReadDeadline = .milliseconds(200)
        await h.coordinator.retryPendingSessions()
        let raised = try #require(h.appState.activeAlarms[.recordingFolderUnavailable]?.message, "its own bound ran out: said")
        #expect(raised.contains("isn’t answering") && !raised.contains("reachable"), "\(raised)")
        #expect(RecordingSentinel.readPending(directory: h.tmp).count == 1, "still pending")
        await h.coordinator.retryPendingSessions()   // the next event, the folder still not answering
        #expect(h.appState.activeAlarms[.recordingFolderUnavailable] != nil, "a raised alarm stays raised")
        hung.release()
        _ = await earlier.value
    }
}

// MARK: - Evidence: provenance, commits, attribution (139, 140, 142, 144, 146, 157, 167)

@MainActor
@Suite struct RecordingCoordinatorEvidenceRoundCTests {
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

    /// L review 139, CRITICAL, end to end with a REAL `SessionEvidence`: a relaunch salvage binds the session (its
    /// adopt) and builds its record — and the recording's own `.diag.jsonl`, written by the process that recorded it,
    /// is kept as it was; the relaunch's record goes beside it.
    @Test func aRelaunchSalvageNeverOverwritesTheRecordingsOwnRecord() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let p = try pendingSession(h, "p")
        let dir = outDir(p)
        do {   // the process that recorded it: an anomaly in its live log, and its own record on disk
            let recorder = SessionEvidence()
            recorder.beginCapture(sessionId: "p", directory: dir)
            recorder.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .xpcInterruption, severity: .anomaly))
            LiveDiagnosticsLog.flushAll()
        }
        let original = Data("the recording's own record\n".utf8)
        try original.write(to: dir.appendingPathComponent("p.diag.jsonl"))
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.client.realEvidence = SessionEvidence(folderReads: FolderReads(label: "rc-c-\(UUID().uuidString)"))
        await h.coordinator.retryPendingSessions()
        #expect(h.presented.value.map(\.lastPathComponent) == ["p.json"], "salvaged")
        #expect(try Data(contentsOf: dir.appendingPathComponent("p.diag.jsonl")) == original, "the recording's own record is kept")
        #expect(try String(contentsOf: dir.appendingPathComponent("p.relaunch.diag.jsonl"), encoding: .utf8).contains("xpcInterruption"))
    }

    /// A re-attached recording without a chunk pipeline: its Stop takes the fallback (a rebuild from disk).
    private func reattachedWithoutPipeline(_ h: Harness) async throws -> RecordingSentinel {
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.isCapturingResult = true
        h.runner.failSetupForTesting = true
        await h.coordinator.recoverAtLaunch()
        #expect(h.appState.isRecording && h.runner.chunkProcessor == nil)
        return s
    }

    /// L review 140: the Stop's fallback commits the evidence ONLY with a transcript. A rebuild that kept the audio
    /// untranscribed (nil) leaves the live log beside it.
    @Test func theStopFallbackCommitsOnlyWithATranscript() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try await reattachedWithoutPipeline(h)
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        h.coordinator.recoverChunkedSessionForTesting = { _, _ in nil }   // the audio kept, untranscribed
        h.client.stopResult = AudioPaths(systemAudio: outDir(s).appendingPathComponent("sess-1.wav"),
                                         micAudio: outDir(s).appendingPathComponent("sess-1_mic.wav"))
        await h.coordinator.stopRecording()
        #expect(!h.client.finalizeCalls.isEmpty, "the record was built")
        #expect(h.client.commitCalls.isEmpty, "never committed without a transcript")
    }

    /// … and with a transcript, the commit comes only once it is on disk (L review 146: the fallback site).
    @Test func theStopFallbackCommitsAfterItsTranscript() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try await reattachedWithoutPipeline(h)
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        let transcriptThere = Harness.Box(false)
        h.client.onCommit = { id, dir in transcriptThere.value = FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).json").path) }
        h.client.stopResult = AudioPaths(systemAudio: outDir(s).appendingPathComponent("sess-1.wav"),
                                         micAudio: outDir(s).appendingPathComponent("sess-1_mic.wav"))
        await h.coordinator.stopRecording()
        #expect(h.client.commitCalls == ["sess"] && transcriptThere.value)
    }

    /// L review 146, the legacy single-file site: a transcript that could not be written commits nothing.
    @Test func theLegacyStopCommitsNothingWithoutATranscript() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try await reattachedWithoutPipeline(h)
        h.client.stopResult = AudioPaths(systemAudio: outDir(s).appendingPathComponent("sess-3.wav"),
                                         micAudio: outDir(s).appendingPathComponent("sess-3_mic.wav"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: outDir(s).path)   // no transcript can be written
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outDir(s).path) }
        await h.coordinator.stopRecording()   // no session.json: the legacy single-file run
        #expect(h.client.finalizeCalls.first?.sessionId == "sess")
        #expect(!FileManager.default.fileExists(atPath: outDir(s).appendingPathComponent("sess.json").path))
        #expect(h.client.commitCalls.isEmpty, "never committed without a transcript")
    }

    /// L review 146, the salvage site: a pending salvage commits only once its transcript is on disk.
    @Test func aSalvageCommitsOnlyOnceItsTranscriptIsOnDisk() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        try RecordingSentinel.writePending([try pendingSession(h, "p")], directory: h.tmp)
        let transcriptThere = Harness.Box(false)
        h.client.onCommit = { id, dir in transcriptThere.value = FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).json").path) }
        await h.coordinator.retryPendingSessions()
        #expect(h.client.commitCalls == ["p"] && transcriptThere.value)
    }

    /// L review 142: a pending retry whose drain of the stray helper did not answer salvages NOTHING this pass — no
    /// salvage binds and drains the helper's events as its own. The sessions wait for the next event.
    @Test func aRetryWhoseDrainDidNotAnswerSalvagesNothing() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let p = try pendingSession(h, "p")
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.client.attributionAnswers = false
        await h.coordinator.retryPendingSessions()
        #expect(h.client.evidenceOrder == ["attribute:p"], "\(h.client.evidenceOrder)")
        #expect(pending(h).map(\.sessionKey) == [p.sessionKey] && h.presented.value.isEmpty, "it waits")
        h.client.attributionAnswers = true
        await h.coordinator.retryPendingSessions()   // the next event
        #expect(pending(h).isEmpty && h.presented.value.count == 1)
    }

    /// L review 167: while the helper still holds a HELD session's capture, the other sessions' salvages bind without
    /// draining it — its events wait for the held session's own salvage — and nothing attributes them meanwhile.
    @Test func aHeldHelpersEventsAreNeverDrainedIntoAnotherSalvage() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let older = try pendingSession(h, "old", in: "other")
        try RecordingSentinel.writePending([older], directory: h.tmp)
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID(); s.stopping = true
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.isCapturingResult = true
        h.coordinator.helperStopDeadline = .milliseconds(100)
        let stuckStop = HungStep()   // the helper's stop hangs until released: it never outlives the test
        defer { stuckStop.release() }
        h.client.onStop = { await stuckStop.hangAwaited() }   // the helper will not let go of `s`
        await h.coordinator.recoverAtLaunch()
        #expect(h.presented.value.map(\.lastPathComponent) == ["old.json"], "the other one is finished")
        #expect(h.client.evidenceOrder.contains("adopt-undrained:old"), "\(h.client.evidenceOrder)")
        #expect(!h.client.evidenceOrder.contains { $0.hasPrefix("attribute:") || $0 == "adopt:old" }, "the stuck helper is never drained")
    }

    /// L review 144: a session found already transcribed (a crash between its transcript and the commit) commits its
    /// evidence now: its transcript verified, its live log and coverage go.
    @Test func anAlreadyTranscribedSessionCommitsItsEvidence() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let p = try pendingSession(h, "p")
        let dir = outDir(p)
        _ = try #require(try await ChunkedSessionRecovery.recover(outputDirectory: dir, sessionId: "p", config: h.config.config,
                                                                   transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: h.runner))
        do {   // its live log, never committed: the crash came first
            let recorder = SessionEvidence()
            recorder.beginCapture(sessionId: "p", directory: dir)
            recorder.record(CaptureEvent(timestamp: Date(timeIntervalSince1970: 5), origin: .app, kind: .retry, severity: .warning))
        }
        LiveDiagnosticsLog.flushAll()
        try RecordingSentinel.writePending([p], directory: h.tmp)
        h.client.realEvidence = SessionEvidence(folderReads: FolderReads(label: "rc-c-\(UUID().uuidString)"))
        await h.coordinator.retryPendingSessions()
        LiveDiagnosticsLog.flushAll()
        #expect(h.client.commitCalls == ["p"], "\(h.client.commitCalls)")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("p.diag.live.jsonl").path), "the live log went")
        #expect(h.presented.value.isEmpty, "nothing transcribed again")
    }

    /// L review 157: a start the helper refuses as busy with an earlier (held) capture drained THAT capture's events:
    /// they are given to the pending session that knows them — never lost with the refused start's evidence.
    @Test func whatARefusedStartDrainedGoesToTheHeldSession() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        let held = try pendingSession(h, "held")
        try RecordingSentinel.writePending([held], directory: h.tmp)
        h.client.startError = HelperReplyError(reply: CaptureReplies.alreadyInProgress)
        h.client.isCapturingResult = true
        await h.coordinator.startRecording(sessionName: "new", microphoneDeviceId: nil)
        #expect(h.client.evidenceOrder.contains("attribute-refused:held"), "\(h.client.evidenceOrder)")
    }
}

// MARK: - Exits, the relaunch probe, re-checks, a late wake (141, 145, 159, 161, 162)

@MainActor
@Suite struct RecordingCoordinatorExitAndRecheckRoundCTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }
    private func pending(_ h: Harness) -> [RecordingSentinel] { RecordingSentinel.readPending(directory: h.tmp) }
    private func outDir(_ s: RecordingSentinel) -> URL { URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent() }
    private func slot(_ h: Harness, alive: TimeInterval, boot: String? = BootSession.currentUUID()) throws -> RecordingSentinel {
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-alive); s.bootSessionUUID = boot
        try RecordingSentinel.write(s, directory: h.tmp)
        return s
    }
    private func hanging(_ hung: HungStep) -> FolderReads {
        FolderReads(label: "rc-c-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
    }

    /// L review 145: the termination's evidence flush takes what is LEFT of the termination's bound — never a whole flush
    /// bound past its deadline.
    @Test func theTerminationFlushNeverRunsPastItsBound() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.client.onStop = { try? await Task.sleep(for: .milliseconds(250)) }
        // The flush hangs until released, and its OWN bound is far longer than the hang's watchdog: a flush given a whole
        // flush bound would hold the preparation until the hang was let go. Given what was left of the 400 ms, the
        // preparation returns with the flush still hung (by order — however late a loaded machine fires the 400 ms).
        let flush = HungStep()
        defer { flush.release() }
        h.client.onFlush = { await flush.hangAwaited() }
        h.coordinator.evidenceFlushBound = .seconds(60)
        await h.coordinator.prepareForTermination(bound: .milliseconds(400))
        #expect(flush.isHanging, "the flush got only what was left of the 400 ms: its own bound was never waited out")
        #expect(h.client.flushCalls == 1)
    }

    /// L review 159: the relaunch probe counts as a start in flight only until the helper has settled. A launch SALVAGE is
    /// not a start: a termination (and the Quit that precedes it) during one neither waits for it nor asks anything.
    @Test func aTerminationDuringALaunchSalvageIsNotHeldByIt() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try slot(h, alive: 3600, boot: "another-boot")
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        let build = HungStep()   // the salvage hangs in its record's build until released
        defer { build.release() }
        h.client.onFinalizeDiagnostics = { await build.hangAwaited() }
        let coordinator = h.coordinator
        let relaunch = Task { await coordinator.recoverAtLaunch() }
        await Harness.until(within: 20) { build.reached }
        #expect(!coordinator.isStartInFlight, "the helper settled: the salvage is no start")
        let confirmed = Harness.Box(false)
        #expect(await coordinator.prepareForQuit(confirm: { confirmed.value = true; return true }))
        #expect(!confirmed.value, "nothing to ask: no recording, no start")
        // Its bound is longer than the hang's watchdog: a termination that waited for the salvage returns only once the
        // salvage ended. By order, never a stopwatch.
        await coordinator.prepareForTermination(bound: .seconds(60))
        #expect(build.isHanging, "never held for the salvage: it returned with the salvage still in its build")
        build.release()
        await relaunch.value
    }

    /// L review 161: the resume re-checks with the FULL check — a Start the user committed (announced) during its folder
    /// scan owns the app: the resume never starts over it, the session waits for the next idle.
    @Test func aResumeYieldsToAStartAnnouncedDuringItsScan() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try slot(h, alive: 5)
        let hung = HungStep("resume: session folder")
        defer { hung.release() }
        h.coordinator.folderReads = hanging(hung)
        let coordinator = h.coordinator
        let relaunch = Task { await coordinator.recoverAtLaunch() }
        await Harness.until { hung.reached }
        coordinator.announceStart()   // the session dialog closed: the user's Start is committed
        hung.release()
        await relaunch.value
        #expect(h.client.startCalls.isEmpty, "never a resume over the user's Start")
        #expect(pending(h).map(\.sessionKey) == [s.sessionKey] && coordinator.retryPendingWhenIdle)
        #expect(h.client.captureEndedCalls == 0)
    }

    /// L review 161: a finalized session found by the resume's scan is left to the salvage — but a Start that got in during
    /// the scan is yielded to FIRST: its crash detection is never disarmed.
    @Test func aFinalizedResumeNeverDisarmsAStartThatGotIn() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try slot(h, alive: 5)
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        _ = try #require(try await ChunkedSessionRecovery.recover(outputDirectory: outDir(s), sessionId: "sess", config: h.config.config,
                                                                   transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: h.runner))
        let hung = HungStep("resume: session folder")
        defer { hung.release() }
        h.coordinator.folderReads = hanging(hung)
        let coordinator = h.coordinator
        let relaunch = Task { await coordinator.recoverAtLaunch() }
        await Harness.until { hung.reached }
        coordinator.announceStart()
        hung.release()
        await relaunch.value
        #expect(h.client.captureEndedCalls == 0, "the Start's crash detection is never disarmed")
        #expect(pending(h).map(\.sessionKey) == [s.sessionKey])
    }

    /// L review 161: a Start that got in during the relaunch's folder read is checked for BEFORE the relaunch arms crash
    /// detection and pings the helper — the relaunch touches nothing of it.
    @Test func aStartDuringTheRelaunchFolderReadIsNeverArmedOver() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try slot(h, alive: 5)
        let hung = HungStep("relaunch: recording folder")
        defer { hung.release() }
        h.coordinator.folderReads = hanging(hung)
        let coordinator = h.coordinator
        let relaunch = Task { await coordinator.recoverAtLaunch() }
        await Harness.until { hung.reached }
        coordinator.announceStart()
        hung.release()
        await relaunch.value
        #expect(h.client.captureReattachedCalls == 0 && h.client.isCapturingCalls == 0, "neither armed nor pinged")
        #expect(pending(h).map(\.sessionKey) == [s.sessionKey])
    }

    /// L review 161: launch recovery waiting for the gate (a retry holds it) already counts as busy: Record is disabled,
    /// and an exit waits for it.
    @Test func launchRecoveryWaitingForTheGateIsBusy() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let folder = h.tmp.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RecordingSentinel.writePending([RecordingSentinel(startedAt: Date(), sessionName: "p", systemAudioPath: folder.appendingPathComponent("p-0.wav").path,
                                                              micAudioPath: folder.appendingPathComponent("p-0_mic.wav").path, stopping: true)],
                                           directory: h.tmp)
        let hung = HungStep("pending folder")
        defer { hung.release() }
        h.coordinator.folderReads = hanging(hung)
        let coordinator = h.coordinator
        let retry = Task { await coordinator.retryPendingSessions() }   // holds the gate during its folder read
        await Harness.until { hung.reached }
        #expect(!coordinator.isStartInFlight, "a retry's folder read is not a start")
        let launch = Task { await coordinator.recoverAtLaunch() }
        await Harness.until { coordinator.isStartInFlight }
        #expect(coordinator.isStartInFlight, "waiting for the gate is busy already")
        hung.release()
        await retry.value
        await launch.value
        #expect(!coordinator.isStartInFlight)
    }

    /// L review 161: the pending retry's own helper stop counts as busy: Record is disabled while it runs.
    @Test func thePendingRetrysHelperStopIsBusy() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let folder = h.tmp.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RecoveryFixtures.writeSessionJSON(dir: folder, sessionId: "p", meetingStart: Date(), chunkIndices: [0])
        try RecordingSentinel.writePending([RecordingSentinel(startedAt: Date(), sessionName: "p", systemAudioPath: folder.appendingPathComponent("p-0.wav").path,
                                                              micAudioPath: folder.appendingPathComponent("p-0_mic.wav").path, stopping: true)],
                                           directory: h.tmp)
        let coordinator = h.coordinator
        let busy = Harness.Box(false)
        h.client.onStop = { busy.value = coordinator.isStartInFlight }
        await coordinator.retryPendingSessions()
        #expect(h.client.stopCalls == 1 && busy.value, "busy while the helper is asked to stop")
        #expect(!coordinator.isStartInFlight)
    }

    private func recording(_ h: Harness, clock: ManualTestClock) async throws {
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        h.coordinator.wakeWatchdogClock = clock
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try FileManager.default.createDirectory(at: try #require(h.client.startCalls.first).outputDirectory, withIntermediateDirectories: true)
    }

    /// L review 162: a late didWake after the watchdog's implicit wake, once the capture's frames came back since, records
    /// no second gap: that audio WAS captured. Nothing is redone.
    @Test func aLateWakeAfterTheFramesCameBackRecordsNoSecondGap() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let clock = ManualTestClock()
        try await recording(h, clock: clock)
        h.coordinator.systemWillSleep(at: Date().addingTimeInterval(-3600))
        await Harness.until { clock.pendingSleeps > 0 }
        clock.advance(by: .seconds(30))
        await Harness.until { h.client.rotateCalls == 1 }
        h.coordinator.noteFirstFrames(track: .mic, helperSessionId: "1000-1")   // the capture's frames are back
        #expect(h.coordinator.framesSinceImplicitWake, "noted: the frames came back after the implicit wake (L review 196)")
        h.appState.interruptionWarning = nil
        h.coordinator.systemDidWake(at: Date())
        #expect(!h.coordinator.framesSinceImplicitWake && h.coordinator.implicitWakeAt == nil, "settled by the real wake")
        await Harness.settle()
        let gaps = try #require(await h.runner.chunkProcessor?.getSessionState().gaps)
        #expect(gaps.count == 1, "no gap over captured audio")
        #expect(h.client.rotateCalls == 1 && h.appState.interruptionWarning == nil, "nothing redone")
        #expect(h.client.powerEvents == ["sleep", "wake"])
    }

    /// L review 162: a willSleep after an implicit wake clears its mark: the next didWake is that new sleep's own.
    @Test func aSleepAfterAnImplicitWakeClearsItsMark() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let clock = ManualTestClock()
        try await recording(h, clock: clock)
        h.coordinator.systemWillSleep(at: Date().addingTimeInterval(-3600))
        await Harness.until { clock.pendingSleeps > 0 }
        clock.advance(by: .seconds(30))
        await Harness.until { h.client.rotateCalls == 1 }
        #expect(h.coordinator.implicitWakeAt != nil)
        h.coordinator.systemWillSleep(at: Date())
        #expect(h.coordinator.implicitWakeAt == nil, "the new sleep settles the last one's implicit wake")
    }
}

// MARK: - Honest outcomes: causes, the Stop's reply, read-backs, rebuilds, folders, lists (147–150, 157, 163, 166)

@MainActor
@Suite struct RecordingCoordinatorOutcomeRoundCTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }
    private func pending(_ h: Harness) -> [RecordingSentinel] { RecordingSentinel.readPending(directory: h.tmp) }
    private func outDir(_ s: RecordingSentinel) -> URL { URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent() }
    private func hanging(_ hung: HungStep) -> FolderReads {
        FolderReads(label: "rc-c-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
    }

    /// L review 147: a session kept pending by a launch that saw a CRASH (its folder was missing) and salvaged later, in
    /// another boot, is worded as the crash — never "your Mac restarted".
    @Test func aCrashKeptInOneBootIsNeverWordedAsARestartInTheNext() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-3600); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        // The drive is away: nothing of the folder is there — but `/` is, as on every Mac. With NOTHING there, the walk up to
        // the nearest existing folder ends only where the root's parent is the root again; a Foundation that answers `/..`
        // for it (the NSURL-backed URL) walks on for ever, and this test's folder reads then never answer (CI, macOS 15).
        h.coordinator.folderProbe = .init(exists: { $0.path == "/" }, isWritable: { _ in false }, isVolumeRoot: { _ in false })
        await h.coordinator.recoverAtLaunch()
        var kept = try #require(pending(h).first)
        #expect(kept.stopCause == .appCrash, "stamped with what this launch saw")
        kept.bootSessionUUID = "the-boot-before"   // the next launch is in ANOTHER boot
        try RecordingSentinel.writePending([kept], directory: h.tmp)
        h.coordinator.folderProbe = .live   // the drive is back
        await h.coordinator.retryPendingSessions()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("Parley crashed") && !row.contains("restarted"), "\(row)")
    }

    /// … and a session kept by a failed start whose helper would not let go says its capture failed — not a crash.
    @Test func aHeldFailedCaptureIsWordedAsTheCaptureNotACrash() throws {
        var s = RecordingSentinel(startedAt: Date(), sessionName: "s", systemAudioPath: "/x/s-0.wav", micAudioPath: "/x/s-0_mic.wav",
                                  bootSessionUUID: "another-boot", stopping: true, stopCause: .captureFailed)
        let outcome = SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0)
        #expect(RecoveryMessages.relaunchStopped(at: Date(), outcome: outcome, cause: .captureFailed).contains("its capture failed"))
        #expect(RecoveryMessages.relaunchStopped(at: Date(), outcome: outcome, cause: .folderNotAnswering).contains("recording folder stopped answering"))
        // The cause travels with the session, and an older file without one still decodes.
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(RecordingSentinel.self, from: data).stopCause == .captureFailed)
        s.stopCause = nil
        #expect(try JSONDecoder().decode(RecordingSentinel.self, from: try JSONEncoder().encode(s)).stopCause == nil)
    }

    /// L review 148: the user's Stop finds ANOTHER stop under way in the helper ("Refused: capture is starting or
    /// stopping"). It waits for it — asking again — and when that outlasts the Stop's deadline, the session is HELD: the
    /// mic stays marked, nothing is re-ingested or finalized now, and no wire text reaches the user.
    @Test func aStopRefusedWhileAnotherStopRunsWaitsThenHolds() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "mic-1")
        let call = try #require(h.client.startCalls.first)
        h.client.stopError = RefusedStoppingError()
        h.coordinator.stopDeadline = .milliseconds(300)
        h.coordinator.stopReaskInterval = .milliseconds(50)
        h.coordinator.stopReaskMinimumBudget = .milliseconds(10)
        await h.coordinator.stopRecording()
        #expect(h.client.stopCalls > 1, "asked again while the other stop ran")
        #expect(h.recordingMic.current == .some("mic-1"), "the mic stays marked: the helper may still hold it")
        #expect(h.client.finalizeCalls.isEmpty, "nothing finalized while its files may still be written")
        #expect(pending(h).map(\.sessionKey) == [call.outputDirectory.appendingPathComponent(call.sessionId).path])
        #expect(h.appState.isIdle)
        let said = (h.appState.errorMessage ?? "") + (h.appState.activeAlarms[.recordingStopped]?.message ?? "")
        #expect(!said.contains(CaptureReplies.refusedStopping), "never the wire text: \(said)")
        #expect(said.contains("another stop is still under way"))
    }

    /// … and when the other stop ends while the Stop waits, the capture is over: the session is salvaged — its last chunk
    /// re-ingested, now sealed — and said in words.
    @Test func aStopThatOutwaitsAnotherStopSalvagesTheSession() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "mic-1")
        let call = try #require(h.client.startCalls.first)
        try FileManager.default.createDirectory(at: call.outputDirectory, withIntermediateDirectories: true)
        try Harness.headerOnlyWAV().write(to: call.outputDirectory.appendingPathComponent(call.baseName + ".wav"))
        h.coordinator.stopReaskInterval = .milliseconds(20)
        h.coordinator.stopReaskMinimumBudget = .milliseconds(10)
        let client = h.client
        client.stopError = RefusedStoppingError()
        client.onStop = { if client.stopCalls == 3 { client.stopError = NoCaptureError() } }   // the other stop ended
        await h.coordinator.stopRecording()
        #expect(h.client.stopCalls == 3)
        #expect(h.recordingMic.current == .none, "the helper let go")
        #expect(h.client.finalizeCalls.count == 1 && pending(h).isEmpty, "salvaged")
        #expect(h.appState.errorMessage == "the capture had already stopped", "\(String(describing: h.appState.errorMessage))")
        let body = h.criticals.value.last?.body ?? ""
        #expect(!body.contains(CaptureReplies.noCaptureInProgress), "never the wire text: \(body)")
    }

    /// L review 149: a salvage whose transcript cannot be read back to count its recognition failures never calls the
    /// chunks "transcribed": it says the transcript could not be checked.
    @Test func aTranscriptThatCannotBeReadBackIsNeverCalledTranscribed() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let dir = h.tmp.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "p", meetingStart: Date(), chunkIndices: [0])
        try RecordingSentinel.writePending([RecordingSentinel(startedAt: Date(), sessionName: "p", systemAudioPath: dir.appendingPathComponent("p-0.wav").path,
                                                              micAudioPath: dir.appendingPathComponent("p-0_mic.wav").path, stopping: true)],
                                           directory: h.tmp)
        let hung = HungStep("salvage: transcript")
        defer { hung.release() }
        h.coordinator.folderReads = hanging(hung)
        h.coordinator.folderReadDeadline = .milliseconds(150)
        await h.coordinator.retryPendingSessions()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(!row.contains("transcribed to") && row.contains("could not be read back to check them"), "\(row)")
    }

    /// A FINALIZED session whose transcript cannot be read back (L review 93b), for the rebuild tests.
    private func damagedFinalized(_ h: Harness, keepProgress: Bool) async throws -> RecordingSentinel {
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-3600); s.bootSessionUUID = "another-boot"
        try RecordingSentinel.write(s, directory: h.tmp)
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        let result = try #require(try await ChunkedSessionRecovery.recover(outputDirectory: outDir(s), sessionId: "sess", config: h.config.config,
                                                                            transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: h.runner))
        if keepProgress { try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0]) }
        try Data("{ damaged".utf8).write(to: result.jsonPath)
        return s
    }

    /// L review 150: a rebuild says the transcript was REBUILT and names the damaged copy it kept; an earlier summary is
    /// moved aside with it (R2), so the rebuild's rename panel and auto-summary never overwrite it.
    @Test func aRebuildSaysSoAndKeepsTheDamagedCopyAndTheSummary() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try await damagedFinalized(h, keepProgress: true)
        let summary = Data("the earlier summary".utf8)
        try summary.write(to: outDir(s).appendingPathComponent("sess-summary.md"))
        await h.coordinator.recoverAtLaunch()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("REBUILT") && row.contains("sess.damaged.json"), "\(row)")
        #expect(try Data(contentsOf: outDir(s).appendingPathComponent("sess-summary.damaged.md")) == summary, "the summary is kept aside")
        #expect(!FileManager.default.fileExists(atPath: outDir(s).appendingPathComponent("sess-summary.md").path), "nothing for the auto-summary to overwrite")
    }

    /// … and with no progress file to rebuild from, it never claims the audio "could not be transcribed": it was.
    @Test func anUnreadableTranscriptWithNothingToRebuildFromIsSaidAsSuch() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try await damagedFinalized(h, keepProgress: false)
        try Harness.headerOnlyWAV().write(to: outDir(s).appendingPathComponent("sess-0.wav"))   // its audio, on disk
        await h.coordinator.recoverAtLaunch()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(!row.contains("could not be transcribed") && row.contains("could not be read back, and no progress file"), "\(row)")
        #expect(row.contains("Its audio (1 chunk) is kept on disk"), "\(row)")
    }

    /// L review 157: a Flow A re-attach never continues a session that was already transcribed (a held restart's helper
    /// went on writing it): its capture is stopped and the salvage cleans up — never a second finalize over the
    /// transcript.
    @Test func aFinishedSessionIsNeverReattached() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        _ = try #require(try await ChunkedSessionRecovery.recover(outputDirectory: outDir(s), sessionId: "sess", config: h.config.config,
                                                                   transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: h.runner))
        h.client.isCapturingResult = true
        h.client.stopResult = AudioPaths(systemAudio: outDir(s).appendingPathComponent("sess-1.wav"), micAudio: outDir(s).appendingPathComponent("sess-1_mic.wav"))
        await h.coordinator.recoverAtLaunch()
        #expect(!h.appState.isRecording, "never re-attached")
        #expect(h.client.stopCalls == 1, "its capture stopped")
        // Its record is built (L review 200) — never its transcript finalized again. The helper just let go of THIS session:
        // its events are this session's, and go into its record (L review 248).
        #expect(h.presented.value.isEmpty, "never finalized again")
        #expect(h.client.drains == ["adopt:sess", "finalize:sess"], "\(h.client.drains)")
        #expect(RecordingSentinel.read(directory: h.tmp) == nil && pending(h).isEmpty)
    }

    /// L review 163: a failed crash restart whose restart-file read does not answer never finalizes without that file:
    /// the session is kept — salvage-only — for when the folder answers, and said so.
    @Test func aRestartFileTheFolderDoesNotShowIsKeptNotDropped() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let call = try #require(h.client.startCalls.first)
        try FileManager.default.createDirectory(at: call.outputDirectory, withIntermediateDirectories: true)
        h.client.startError = FakeCaptureError()
        h.client.stopResult = AudioPaths(systemAudio: call.outputDirectory.appendingPathComponent("x.wav"),
                                         micAudio: call.outputDirectory.appendingPathComponent("x_mic.wav"))
        let hung = HungStep("crash restart: restart file")
        defer { hung.release() }
        h.coordinator.folderReads = hanging(hung)
        h.coordinator.folderReadDeadline = .milliseconds(150)
        await h.coordinator.handleXPCCrash()
        #expect(h.appState.isIdle)
        #expect(h.client.finalizeCalls.isEmpty, "never a transcript written without the restart's file")
        let kept = try #require(pending(h).first)
        #expect(kept.stopping && kept.stopCause == .folderNotAnswering)
        #expect(h.criticals.value.last?.body.contains("isn’t answering") == true, "\(h.criticals.value)")
    }

    /// L review 163: a Stop whose session has no recovery file left, and whose folder does not answer, is KEPT — "Parley
    /// will finish it when the folder answers" is only ever said about something kept (the same rule serves a crash with
    /// no recovery file).
    @Test func aStopWithoutARecoveryFileIsKeptWhenTheFolderDoesNotAnswer() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.isCapturingResult = true
        h.runner.failSetupForTesting = true   // re-attached without a pipeline: the Stop reads the folder itself
        await h.coordinator.recoverAtLaunch()
        RecordingSentinel.delete(directory: h.tmp)   // the recovery file is gone
        let hung = HungStep("stop: session folder")
        defer { hung.release() }
        h.coordinator.folderReads = hanging(hung)
        h.coordinator.folderReadDeadline = .milliseconds(150)
        h.client.stopResult = AudioPaths(systemAudio: outDir(s).appendingPathComponent("sess-1.wav"), micAudio: outDir(s).appendingPathComponent("sess-1_mic.wav"))
        await h.coordinator.stopRecording()
        #expect(h.appState.isIdle)
        let body = h.criticals.value.last?.body ?? ""
        #expect(body.contains("when the folder answers"), "\(body)")
        let kept = try #require(pending(h).first, "kept, as promised")
        #expect(kept.sessionKey == s.sessionKey && kept.stopping && kept.stopCause == .folderNotAnswering)
    }

    /// L review 166: an unreadable pending list that cannot even be moved aside never leaves a new hold untracked: the
    /// hold goes to a NEW list beside it, which the pending sessions include — a next Start's sentinel never takes its
    /// place — and the row says where things are.
    @Test func aHoldIsTrackedWhenTheListCannotBeMovedAside() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: h.tmp.appendingPathComponent("pending-sessions.json").path)
            tearDown(h)
        }
        let list = h.tmp.appendingPathComponent("pending-sessions.json")
        try Data("not a list".utf8).write(to: list)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: list.path)   // cannot be moved aside
        h.client.startError = CaptureCallTimeout(call: "start", seconds: 15)
        h.coordinator.helperStopDeadline = .milliseconds(100)
        let stuckStop = HungStep()   // the helper's stop hangs until released: it never outlives the test
        defer { stuckStop.release() }
        h.client.onStop = { await stuckStop.hangAwaited() }   // the helper will not let go: HELD
        await h.coordinator.startRecording(sessionName: "held", microphoneDeviceId: nil)
        let held = try #require(pending(h).first, "the hold is tracked")
        h.client.startError = nil
        h.client.onStop = nil
        await h.coordinator.startRecording(sessionName: "next", microphoneDeviceId: nil)   // writes the slot
        #expect(pending(h).map(\.sessionKey) == [held.sessionKey], "still tracked after the next Start")
        #expect(try Data(contentsOf: list) == Data("not a list".utf8), "the unreadable list is never overwritten")
        // The list's own row (L review 249) — and the hold's own, never taken by it.
        let row = try #require(h.appState.activeAlarms[.pendingListUnreadable]?.message)
        #expect(row.contains("separate list"), "\(row)")
        let hold = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(hold.contains("couldn’t stop the capture"), "\(hold)")
    }
}

// MARK: - The transcript's and the rebuild's folder looks (158)

@MainActor
@Suite struct RecordingCoordinatorTranscriptReadsRoundCTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }
    private func pending(_ h: Harness) -> [RecordingSentinel] { RecordingSentinel.readPending(directory: h.tmp) }
    private func hanging(_ hung: HungStep) -> FolderReads {
        FolderReads(label: "rc-c-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
    }

    /// L review 158: the transcript's look at its folder (which chunk files are there, the leftover WAVs) runs off the
    /// main actor, bounded. A Stop whose folder stops answering there is never finalized blind, and never frozen: the
    /// session is kept for when the folder answers, and its evidence is not committed.
    @Test func aStopWhoseTranscriptFolderDoesNotAnswerIsKept() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let call = try #require(h.client.startCalls.first)
        try FileManager.default.createDirectory(at: call.outputDirectory, withIntermediateDirectories: true)
        let sys = call.outputDirectory.appendingPathComponent(call.baseName + ".wav")
        try Harness.headerOnlyWAV().write(to: sys)
        h.client.stopResult = AudioPaths(systemAudio: sys, micAudio: call.outputDirectory.appendingPathComponent(call.baseName + "_mic.wav"))
        let hung = HungStep("transcript: chunk files")
        defer { hung.release() }
        h.coordinator.folderReads = hanging(hung)
        h.coordinator.folderReadDeadline = .milliseconds(150)
        let began = ContinuousClock.now
        await h.coordinator.stopRecording()
        #expect(ContinuousClock.now - began < .seconds(3), "bounded")
        #expect(h.appState.isIdle && h.client.commitCalls.isEmpty)
        let kept = try #require(pending(h).first, "kept for when the folder answers")
        #expect(kept.sessionKey == call.outputDirectory.appendingPathComponent(call.sessionId).path && kept.stopCause == .folderNotAnswering)
        #expect(h.criticals.value.last?.body.contains("isn’t answering") == true, "\(h.criticals.value)")
    }

    /// L review 158: the rebuild from disk reads its folder off the main actor, bounded. A salvage whose folder does not
    /// answer there waits — pending, its folder said not to answer — never a failure, never a row claiming anything.
    @Test func aSalvageWhoseRebuildFolderDoesNotAnswerWaits() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let dir = h.tmp.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "p", meetingStart: Date(), chunkIndices: [0])
        let p = RecordingSentinel(startedAt: Date(), sessionName: "p", systemAudioPath: dir.appendingPathComponent("p-0.wav").path,
                                  micAudioPath: dir.appendingPathComponent("p-0_mic.wav").path, stopping: true)
        try RecordingSentinel.writePending([p], directory: h.tmp)
        let hung = HungStep("recovery: session folder")
        defer { hung.release() }
        h.coordinator.folderReads = hanging(hung)
        h.coordinator.folderReadDeadline = .milliseconds(150)
        h.coordinator.folderPrepareDeadline = .milliseconds(150)
        await h.coordinator.retryPendingSessions()
        #expect(pending(h).map(\.sessionKey) == [p.sessionKey], "it waits")
        #expect(h.presented.value.isEmpty && h.client.commitCalls.isEmpty)
        #expect(h.appState.isIdle && h.appState.activeAlarms[.recordingStopped] == nil, "nothing claimed")
        #expect(h.appState.activeAlarms[.recordingFolderUnavailable] != nil, "its folder is said not to answer")
    }
}
