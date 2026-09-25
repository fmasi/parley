import Foundation
import Testing
@testable import TranscriberCore

// Stream L, round C (items 139–168): the coordinator's side. The fake client and the harness are
// RecordingCoordinatorTests.swift's.

/// A read queue whose read named `label` hangs until released (or a watchdog does it, so a regression fails instead
/// of wedging the run).
final class HungRead: @unchecked Sendable {
    let label: String
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var began = false
    var reached: Bool { lock.withLock { began } }
    init(_ label: String) { self.label = label }
    func hangIfNamed(_ name: String) {
        guard name == label else { return }
        lock.withLock { began = true }
        _ = semaphore.wait(timeout: .now() + 10)   // the watchdog: never a wedged run
    }
    func release() { semaphore.signal() }
}

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
        let hung = HungRead("dead share")
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

    /// L review 164: a pending folder whose read is coalesced — an earlier read of it has not answered YET — is "no
    /// answer yet": the folder alarm is left as it was, never raised as "not reachable".
    @Test func aCoalescedPendingFolderReadLeavesTheAlarmAlone() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let folder = h.tmp.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RecordingSentinel.writePending([RecordingSentinel(startedAt: Date(), sessionName: "p", systemAudioPath: folder.appendingPathComponent("p-0.wav").path,
                                                              micAudioPath: folder.appendingPathComponent("p-0_mic.wav").path, stopping: true)],
                                           directory: h.tmp)
        let hung = HungRead("earlier read")
        defer { hung.release() }
        h.coordinator.folderReads = FolderReads(label: "rc-c-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        let reads = h.coordinator.folderReads
        let earlier = Task { await reads.read("earlier read", folder: folder.path, seconds: 5) { 0 } }
        await Harness.until { hung.reached }
        await h.coordinator.retryPendingSessions()
        #expect(h.appState.activeAlarms[.recordingFolderUnavailable] == nil, "no answer yet is not \"unreachable\"")
        #expect(RecordingSentinel.readPending(directory: h.tmp).count == 1, "still pending")
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
        h.client.onStop = { try? await Task.sleep(for: .seconds(1)) }   // the helper will not let go of `s`
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
    private func hanging(_ hung: HungRead) -> FolderReads {
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
        h.client.onFlush = { try? await Task.sleep(for: .seconds(3)) }
        h.coordinator.evidenceFlushBound = .seconds(1)
        let began = ContinuousClock.now
        await h.coordinator.prepareForTermination(bound: .milliseconds(400))
        #expect(ContinuousClock.now - began < .milliseconds(800), "the flush got only what was left of the 400 ms")
        #expect(h.client.flushCalls == 1)
    }

    /// L review 159: the relaunch probe counts as a start in flight only until the helper has settled. A launch SALVAGE is
    /// not a start: a termination (and the Quit that precedes it) during one neither waits for it nor asks anything.
    @Test func aTerminationDuringALaunchSalvageIsNotHeldByIt() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try slot(h, alive: 3600, boot: "another-boot")
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        let inBuild = Harness.Box(false), release = Harness.Box(false)
        h.client.onFinalizeDiagnostics = {
            inBuild.value = true
            while !release.value { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let coordinator = h.coordinator
        let relaunch = Task { await coordinator.recoverAtLaunch() }
        await Harness.until { inBuild.value }
        #expect(!coordinator.isStartInFlight, "the helper settled: the salvage is no start")
        let confirmed = Harness.Box(false)
        #expect(await coordinator.prepareForQuit(confirm: { confirmed.value = true; return true }))
        #expect(!confirmed.value, "nothing to ask: no recording, no start")
        let began = ContinuousClock.now
        await coordinator.prepareForTermination(bound: .seconds(2))
        #expect(ContinuousClock.now - began < .milliseconds(500), "never held for the salvage")
        release.value = true
        await relaunch.value
    }

    /// L review 161: the resume re-checks with the FULL check — a Start the user committed (announced) during its folder
    /// scan owns the app: the resume never starts over it, the session waits for the next idle.
    @Test func aResumeYieldsToAStartAnnouncedDuringItsScan() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try slot(h, alive: 5)
        let hung = HungRead("resume: session folder")
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
        let hung = HungRead("resume: session folder")
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
        let hung = HungRead("relaunch: recording folder")
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
        let hung = HungRead("pending folder")
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
        h.appState.interruptionWarning = nil
        h.coordinator.systemDidWake(at: Date())
        for _ in 0..<50 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
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
