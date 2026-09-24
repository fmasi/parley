import Testing
import Foundation
@testable import TranscriberCore

/// Tests for the recording-lifecycle + crash-recovery orchestration extracted from MenuView
/// (#139 audit finding 3 / PR-6). Uses a fake capture client — no real audio, no XPC — and a
/// per-test sentinel directory so nothing touches the real app-support path.
@MainActor
private final class FakeCaptureClient: RecordingCaptureClient {
    var onServiceCrash: (@Sendable () -> Void)?
    var onMicDeviceChanged: (@Sendable (String?) -> Void)?
    var onFatalFailure: (@Sendable (String) -> Void)?
    var onQualityAnomaly: (@Sendable (String, String) -> Void)?
    var onSystemAudioUnrecoverable: (@Sendable (String) -> Void)?
    var onBriefInterruption: (@Sendable () -> Void)?
    var onRestartInPlace: (@Sendable () -> Void)?
    var onFirstFrames: (@Sendable (CaptureTrack, String) -> Void)?
    var onAlarmsChanged: (@Sendable (CaptureStatusSnapshot) -> Void)?
    var onRealAudio: (@Sendable (CaptureTrack, String) -> Void)?
    var onWriteSucceeded: (@Sendable (String) -> Void)?

    struct StartCall: Equatable {
        let outputDirectory: URL
        let baseName: String
        let microphoneDeviceId: String?
        let systemAudioSource: SystemAudioSource
        let options: CaptureOptions
        let sessionId: String
    }

    var startCalls: [StartCall] = []
    var startError: Error?
    /// Runs inside start(), i.e. at the moment the helper would be opening the mic.
    var onStart: (() -> Void)?
    /// Awaited inside start(): lets a test suspend the caller mid-start (a crash arriving then).
    var onStartAsync: (() async -> Void)?
    /// Runs inside stop(), i.e. while the helper still holds the mic (and the coordinator is suspended).
    var onStop: (() async -> Void)?
    var micUpdates: [String?] = []
    var updateMicError: Error?
    /// Runs inside updateMicrophone(), i.e. at the moment the helper would be opening the new mic.
    var onUpdateMicrophone: (() async -> Void)?

    func updateMicrophone(deviceId: String?) async throws {
        micUpdates.append(deviceId)
        await onUpdateMicrophone?()
        if let updateMicError { throw updateMicError }
    }
    var stopCalls = 0
    var stopError: Error?
    var stopResult: AudioPaths?
    var retryEvents: [[String: String]] = []
    /// Spy on provenance finalization: which session the orchestration stamped, and where.
    var finalizeCalls: [(sessionId: String, engine: String, recordingDirectory: URL)] = []

    func start(
        outputDirectory: URL,
        baseName: String,
        microphoneDeviceId: String?,
        systemAudioSource: SystemAudioSource,
        options: CaptureOptions,
        sessionId: String
    ) async throws {
        sessionCalls.append("start:\(sessionId)")
        startCalls.append(StartCall(
            outputDirectory: outputDirectory,
            baseName: baseName,
            microphoneDeviceId: microphoneDeviceId,
            systemAudioSource: systemAudioSource,
            options: options,
            sessionId: sessionId
        ))
        onStart?()
        await onStartAsync?()
        if let startError { throw startError }
    }

    var statusSnapshot: CaptureStatusSnapshot?
    /// Takes precedence over `statusSnapshot`: lets a test answer every poll with a NEW sequence.
    var statusProvider: (() -> CaptureStatusSnapshot?)?
    func captureStatus() async -> CaptureStatusSnapshot? { statusProvider?() ?? statusSnapshot }

    var isCapturingResult = false
    /// Overrides `isCapturingResult`: `.unknown` is a ping the helper did not answer (L9 review 49).
    var captureStateResult: HelperCaptureState?
    /// Whether crash detection was armed (`captureReattached`) when the Flow-A ping ran.
    var armedAtPing: Bool?
    /// Whether the crash callbacks were wired when the Flow-A ping ran (L round 5, item 12).
    var wiredAtPing: Bool?
    var isCapturingCalls = 0
    /// Awaited inside captureState(): lets a test act while the ping is outstanding (L round 7).
    var onIsCapturing: (() async -> Void)?
    func captureState() async -> HelperCaptureState {
        isCapturingCalls += 1
        await onIsCapturing?()
        armedAtPing = captureReattachedCalls > 0
        wiredAtPing = onServiceCrash != nil
        return captureStateResult ?? (isCapturingResult ? .capturing : .notCapturing)
    }

    /// The XPC connection dropped after a helper call timed out (L9 review 45).
    var droppedConnections = 0
    var onDropConnection: (() -> Void)?
    func dropConnection() { droppedConnections += 1; onDropConnection?() }

    var launchRecoveries: [[String: String]] = []
    func recordLaunchRecovery(_ detail: [String: String]) { launchRecoveries.append(detail) }

    /// The order of the calls that decide which session the evidence belongs to (L follow-up 43).
    var sessionCalls: [String] = []
    func adoptSession(sessionId: String, directory: URL) async { sessionCalls.append("adopt:\(sessionId)") }

    var powerEvents: [String] = []
    /// Awaited before the event lands: lets a test slow a delivery down (a "sleep" still in flight).
    var onPowerEvent: ((String) async -> Void)?
    func systemPowerEvent(_ kind: String) async {
        await onPowerEvent?(kind)
        powerEvents.append(kind)
    }

    var recordedEvents: [(kind: CaptureEventKind, severity: CaptureEvent.Severity, detail: [String: String])] = []
    func record(_ kind: CaptureEventKind, _ severity: CaptureEvent.Severity, _ detail: [String: String]) {
        recordedEvents.append((kind, severity, detail))
    }

    /// Whether the task running `stop()` was already cancelled (L2/L4 fix round 2, item 3).
    var stopSawCancellation: Bool?
    func stop() async throws -> AudioPaths {
        stopCalls += 1
        stopSawCancellation = Task.isCancelled
        await onStop?()
        if let stopError { throw stopError }
        guard let stopResult else { throw CocoaError(.fileNoSuchFile) }
        return stopResult
    }

    func finalizeSessionDiagnostics(
        sessionId: String, engine: String, recordingDirectory: URL
    ) async -> CaptureProvenance {
        finalizeCalls.append((sessionId, engine, recordingDirectory))
        return CaptureDiagnostics().makeProvenance(
            engine: engine, systemFormat: nil, micFormat: nil, micDevice: nil
        )
    }

    func recordRetry(_ detail: [String: String]) {
        retryEvents.append(detail)
    }

    /// Recordings that ended without `stop()` (C1: crash detection disarmed).
    var captureEndedCalls = 0
    var onCaptureEnded: (() -> Void)?
    func captureEnded() { captureEndedCalls += 1; onCaptureEnded?() }

    /// Captures the app re-attached to without starting them (C1: crash detection armed).
    var captureReattachedCalls = 0
    func captureReattached() { captureReattachedCalls += 1 }

    var rotateError: Error?
    var rotateCalls = 0
    /// Awaited inside rotateChunk(): lets a test hold a rotation in flight.
    var onRotate: (() async -> Void)?
    func rotateChunk(outputDirectory: String, newBaseName: String) async throws
        -> (systemPath: String, micPath: String) {
        rotateCalls += 1
        await onRotate?()
        if let rotateError { throw rotateError }
        return (outputDirectory + "/" + newBaseName + ".wav",
                outputDirectory + "/" + newBaseName + "_mic.wav")
    }
}

private struct FakeCaptureError: Error, LocalizedError {
    var errorDescription: String? { "fake capture failure" }
}

/// The helper's reply to a rotate when it is not capturing: the capture is dead (§8.7).
private struct NoCaptureError: Error, LocalizedError {
    var errorDescription: String? { "No capture in progress" }
}

/// The helper's reply to a rotate while it is stopping (council B-I3, stream H2): not a dead capture.
private struct RefusedStoppingError: Error, LocalizedError {
    var errorDescription: String? { "refused: stopping" }
}

@MainActor
private struct Harness {
    let tmp: URL
    let appState = AppState()
    let client = FakeCaptureClient()
    let runner = TranscriptionRunner()
    let config: ConfigManager
    let coordinator: RecordingCoordinator
    let notified: Box<[(title: String, body: String)]> = Box([])
    let criticals: Box<[(title: String, body: String)]> = Box([])
    let presented: Box<[URL]> = Box([])
    let repairRequests: Box<Int> = Box(0)
    /// What the repair path answers: true = its window presented (L round 4, item 4).
    let repairPresents: Box<Bool> = Box(true)
    /// The free space every disk check reads (L8): plenty unless a test says otherwise, so no test
    /// depends on the machine's real disk.
    let freeBytes: Box<Int?> = Box(Int.max)
    let recordingMic: RecordingMicrophone

    /// `@unchecked Sendable`: tests hand it to `@Sendable` seams (the disk provider); the main actor owns it.
    final class Box<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }

    init(recordingMic: RecordingMicrophone = RecordingMicrophone()) throws {
        self.recordingMic = recordingMic
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        config = ConfigManager(configDir: tmp)  // empty dir -> Config.default
        let notified = notified
        let criticals = criticals
        let presented = presented
        let repairRequests = repairRequests
        let repairPresents = repairPresents
        let freeBytes = freeBytes
        coordinator = RecordingCoordinator(
            appState: appState,
            captureClient: client,
            transcriptionRunner: runner,
            configManager: config,
            sentinelDirectory: tmp,
            notify: { notified.value.append(($0, $1)) },
            notifyCritical: { criticals.value.append(($0, $1)) },
            presentTranscript: { url, _ in presented.value.append(url) },
            onSystemAudioPermissionDenied: { repairRequests.value += 1; return repairPresents.value },
            engineFactory: { _ in (FakeEngine(), FakeDiarizer()) },
            recordingMicrophone: recordingMic,
            freeBytesProvider: { _ in freeBytes.value }
        )
    }

    /// Polls `condition` (up to about 2 s): a deadline, never a fixed number of yields.
    static func until(_ condition: () -> Bool) async {
        var waited = 0
        while !condition(), waited < 400 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            waited += 1
        }
    }

    /// A WAV with a header and no audio: processing it never loads a model (`streamEmpty`).
    static func headerOnlyWAV() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(48_000); u32(96_000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(0)
        return d
    }

    func writeSentinel(
        sessionId: String = "sess", segment: Int = 1, chunkIndex: Int = 0,
        micDeviceUID: String? = "mic-1"
    ) throws -> RecordingSentinel {
        let outDir = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let sentinel = RecordingSentinel(
            startedAt: Date(),
            sessionName: "Test",
            systemAudioPath: outDir.appendingPathComponent("\(sessionId)-0.wav").path,
            micAudioPath: outDir.appendingPathComponent("\(sessionId)-0_mic.wav").path,
            micDeviceUID: micDeviceUID,
            segment: segment,
            chunkIndex: chunkIndex
        )
        try RecordingSentinel.write(sentinel, directory: tmp)
        return sentinel
    }
}

// MARK: - Pure decision helpers

@Suite struct RecordingCoordinatorNamingTests {
    @Test func startNamingUsesTimestampAndZeroIndex() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fmt = DateFormatter()
        fmt.dateFormat = "HHmmss"
        let ts = fmt.string(from: now)
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"

        let naming = RecordingCoordinator.startNaming(sessionName: "Weekly Sync", now: now)
        #expect(naming.dayDir == dayFmt.string(from: now))
        #expect(naming.sanitized == "Weekly Sync")
        #expect(naming.chunkBaseName == "\(ts)-Weekly Sync")
        #expect(naming.baseName == "\(ts)-Weekly Sync-0")
    }

    @Test func startNamingEmptyNameFallsBackToTimestampOnly() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fmt = DateFormatter()
        fmt.dateFormat = "HHmmss"
        let ts = fmt.string(from: now)

        let naming = RecordingCoordinator.startNaming(sessionName: "", now: now)
        #expect(naming.sanitized.isEmpty)
        #expect(naming.chunkBaseName == ts)
        #expect(naming.baseName == "\(ts)-0")
    }

    @Test func startNamingSanitizesUnsafeCharacters() {
        let naming = RecordingCoordinator.startNaming(sessionName: "a/b:c", now: Date())
        #expect(!naming.chunkBaseName.contains("/"))
        #expect(!naming.chunkBaseName.contains(":"))
    }
}

@Suite struct RecordingCoordinatorFallbackDecisionTests {
    private var stoppedPaths: AudioPaths {
        AudioPaths(
            systemAudio: URL(fileURLWithPath: "/stopped/live-3.wav"),
            micAudio: URL(fileURLWithPath: "/stopped/live-3_mic.wav")
        )
    }

    private func sentinel(segment: Int) -> RecordingSentinel {
        RecordingSentinel(
            startedAt: Date(),
            sessionName: "Test",
            systemAudioPath: "/rec/day/sess-2.wav",
            micAudioPath: "/rec/day/sess-2_mic.wav",
            segment: segment,
            chunkIndex: 2
        )
    }

    @Test func sessionLocationPrefersSentinelOverStoppedPaths() {
        let loc = RecordingCoordinator.fallbackSessionLocation(
            sentinel: sentinel(segment: 2), stoppedSystemAudioPath: stoppedPaths.systemAudio.path
        )
        #expect(loc.outputDir.path == "/rec/day")
        #expect(loc.sessionId == "sess")
    }

    @Test func sessionLocationDerivesFromStoppedPathWithoutSentinel() {
        let loc = RecordingCoordinator.fallbackSessionLocation(
            sentinel: nil, stoppedSystemAudioPath: stoppedPaths.systemAudio.path
        )
        #expect(loc.outputDir.path == "/stopped")
        #expect(loc.sessionId == "live")
    }

    @Test func legacyInputsMultiSegmentPointsAtZeroIndexedBase() {
        // #7: a multi-segment session must hand SegmentDiscovery the -0 base so its gap-tolerant
        // 0-indexed mode reclaims every segment; the stripped base would drop the -0 orphan.
        let inputs = RecordingCoordinator.legacySingleFileInputs(
            sentinel: sentinel(segment: 2), stoppedPaths: stoppedPaths
        )
        #expect(inputs.systemAudio.path == "/rec/day/sess-0.wav")
        #expect(inputs.micAudio?.path == "/rec/day/sess-0_mic.wav")
    }

    @Test func legacyInputsSingleSegmentUsesStoppedPaths() {
        let inputs = RecordingCoordinator.legacySingleFileInputs(
            sentinel: sentinel(segment: 1), stoppedPaths: stoppedPaths
        )
        #expect(inputs.systemAudio == stoppedPaths.systemAudio)
        #expect(inputs.micAudio == stoppedPaths.micAudio)
    }

    @Test func legacyInputsNoSentinelUsesStoppedPaths() {
        let inputs = RecordingCoordinator.legacySingleFileInputs(
            sentinel: nil, stoppedPaths: stoppedPaths
        )
        #expect(inputs.systemAudio == stoppedPaths.systemAudio)
        #expect(inputs.micAudio == stoppedPaths.micAudio)
    }

    // #92: the live-pipeline crash branch. The orphan chunk's WAVs must come from the rotator's
    // LIVE base name — the sentinel path (written at session start, e.g. `sess-0`) goes stale
    // after the first rotation; targeting it re-enqueues the already-processed chunk and silently
    // drops the true orphan's audio from the final transcript.
    @Test func orphanChunkTargetsLiveBaseNotStaleSentinelPath() {
        let outputDir = URL(fileURLWithPath: "/rec/day")
        let start = Date()
        let chunk = RecordingCoordinator.orphanChunk(
            index: 2, startTime: start, liveBaseName: "sess-2", outputDir: outputDir
        )
        #expect(chunk.index == 2)
        #expect(chunk.startTime == start)
        #expect(chunk.systemPath == "/rec/day/sess-2.wav")  // the LIVE base…
        #expect(chunk.micPath == "/rec/day/sess-2_mic.wav")
        #expect(!chunk.systemPath.hasSuffix("sess-0.wav"))  // …never the stale sentinel base
    }

    @Test func liveRestartPlanNamesRestartFromRecoveryPlan() {
        let outputDir = URL(fileURLWithPath: "/rec/day")
        let plan = ChunkRecoveryPlan(
            orphanIndex: 2, recoveryIndex: 3, orphanBaseName: "sess-2", recoveryBaseName: "sess-3"
        )
        let restart = RecordingCoordinator.liveRestartPlan(
            sentinel: sentinel(segment: 1), recoveryPlan: plan, outputDir: outputDir
        )
        #expect(restart.baseName == "sess-3")
        #expect(restart.newSentinel.segment == 2)  // old + 1
        #expect(restart.newSentinel.chunkIndex == 3)  // the plan's recovery index, stamped directly
        #expect(restart.newSentinel.systemAudioPath == "/rec/day/sess-3.wav")
        #expect(restart.newSentinel.micAudioPath == "/rec/day/sess-3_mic.wav")
    }
}

// MARK: - Lifecycle orchestration (fake capture client)

@MainActor
@Suite struct RecordingCoordinatorLifecycleTests {
    @Test func startRecordingFailureCleansUpSentinelAndNotifies() async throws {
        let h = try Harness()
        h.client.startError = FakeCaptureError()

        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")

        #expect(h.appState.errorMessage == FakeCaptureError().errorDescription)
        #expect(h.appState.isIdle)
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
        #expect(h.notified.value.map { $0.title } == ["Recording Failed"])
        #expect(h.client.captureEndedCalls == 1, "a start that failed must disarm crash detection (C1)")
        // The crash/fatal/mic-change/quality-anomaly callbacks are wired before start is attempted.
        #expect(h.client.onServiceCrash != nil)
        #expect(h.client.onFatalFailure != nil)
        #expect(h.client.onMicDeviceChanged != nil)
        #expect(h.client.onQualityAnomaly != nil)
        // Sentinel was written before start (then deleted on failure); start saw the -0 base name.
        #expect(h.client.startCalls.count == 1)
        #expect(h.client.startCalls[0].baseName.hasSuffix("-Test-0"))
        #expect(h.client.startCalls[0].microphoneDeviceId == "mic-1")
    }

    // #192: level meters read `RecordingMicrophone` to stay off the mic the helper is capturing.

    @Test func startMarksTheRecordingMicBeforeTheHelperOpensIt() async throws {
        let h = try Harness()
        let recordingMic = h.recordingMic
        var seenAtStart: String??
        h.client.onStart = { seenAtStart = recordingMic.current }

        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")

        #expect(seenAtStart == .some("mic-1"), "a meter could open the mic while the helper was opening it")
        #expect(h.recordingMic.current == .some("mic-1"))
        h.client.onMicDeviceChanged?("mic-2")   // helper auto-switched
        await Task.yield(); await Task.yield()
        #expect(h.recordingMic.current == .some("mic-2"))
    }

    // NOTE: the clamshell preflight in startRecording() (ClamshellMicGuard.isLidClosed() /
    // isBuiltInMicSelected()) has no unit test here — both device queries are real IOKit/CoreAudio
    // HAL calls with no injection seam, so they're device-test only (see PR #217's device-test
    // checklist item 1). What IS covered below is the re-entrancy-guard-before-banner ordering
    // bug this preflight had: the guard must run before `interruptionWarning` is set, or a
    // startRecording call that loses the re-entrancy race still shows a banner for a recording it
    // isn't driving.

    // #193/#196 review fix: onQualityAnomaly must be wired by startRecording itself, not only on the
    // launch-time crash-recovery re-attach paths — otherwise a live anomaly banner never appears
    // during a normal recording.
    @Test func qualityAnomalyDuringNormalRecordingShowsBanner() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        #expect(h.appState.isRecording)

        h.client.onQualityAnomaly?("exactZeroMic", "The microphone has delivered 12s of pure digital silence.")
        for _ in 0..<50 { await Task.yield() }

        #expect(h.appState.interruptionWarning == "The microphone has delivered 12s of pure digital silence.")
    }

    // MARK: - Alarms (§6)

    private func snapshot(_ id: String, _ sequence: UInt64, _ kinds: [AlarmKind]) -> CaptureStatusSnapshot {
        CaptureStatusSnapshot(helperSessionId: id, sequence: sequence, isCapturing: true,
                              alarms: kinds.map { ActiveAlarm(kind: $0, raisedAt: Date(), lastNotifiedAt: nil, message: $0.rawValue, episode: 1) }, tracks: [])
    }

    /// The tap running without its permission: the helper's alarm reaches the app, sticks, and opens repair.
    @Test func helperPermissionAlarmSticksAndOpensRepair() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        h.client.onAlarmsChanged?(snapshot("1000-0", 1, [.remotePermissionDenied]))
        for _ in 0..<50 { await Task.yield() }
        #expect(h.appState.activeAlarms[.remotePermissionDenied] != nil)
        #expect(h.appState.remoteAudioNotCaptured)
        #expect(h.repairRequests.value == 1)
        h.client.onAlarmsChanged?(snapshot("1000-0", 2, [.remotePermissionDenied]))   // the next poll: no second repair window
        for _ in 0..<50 { await Task.yield() }
        #expect(h.repairRequests.value == 1)
    }

    /// The end of a recording clears its alarms without a presentation; the same kind in the NEXT
    /// recording is new again and reopens repair.
    @Test func aPermissionAlarmInTheNextRecordingOpensRepairAgain() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        h.client.onAlarmsChanged?(snapshot("1000-0", 1, [.remotePermissionDenied]))
        for _ in 0..<50 { await Task.yield() }
        #expect(h.repairRequests.value == 1)

        h.appState.phase = .idle
        await h.coordinator.startRecording(sessionName: "Second", microphoneDeviceId: "mic-1")
        #expect(h.appState.isRecording)
        h.client.onAlarmsChanged?(snapshot("1000-1", 1, [.remotePermissionDenied]))
        for _ in 0..<50 { await Task.yield() }
        #expect(h.repairRequests.value == 2)
    }

    @Test func unrelatedAnomalyIsATransientNoticeOnly() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        h.client.onQualityAnomaly?("exactZeroMic", "mic silent")
        for _ in 0..<50 { await Task.yield() }
        #expect(h.appState.interruptionWarning == "mic silent")
        #expect(!h.appState.remoteAudioNotCaptured && h.repairRequests.value == 0)
    }

    @Test func aNewerSnapshotWithoutTheKindClearsTheAlarm() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        h.client.onAlarmsChanged?(snapshot("1000-0", 1, [.remotePermissionDenied]))
        for _ in 0..<50 { await Task.yield() }
        h.client.onAlarmsChanged?(snapshot("1000-0", 2, []))
        for _ in 0..<50 { await Task.yield() }
        #expect(!h.appState.remoteAudioNotCaptured)
    }

    /// The SCK give-up used to be `noteSystemAudioLost`; the sticky part is now the helper's alarm
    /// (`remoteRecoveryFailed`, H2) and the app keeps only the transient notice (scan D2).
    @Test func systemAudioUnrecoverableIsATransientNoticeAndTheHelperAlarmIsSticky() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        h.client.onSystemAudioUnrecoverable?("tap rebuild failed")
        h.client.onAlarmsChanged?(snapshot("1000-0", 1, [.remoteRecoveryFailed]))
        for _ in 0..<50 { await Task.yield() }
        #expect(h.appState.interruptionWarning?.contains("only your microphone") == true)
        #expect(h.appState.remoteAudioNotCaptured)
    }

    @Test func staleSnapshotAfterTheRecordingEndedIsIgnored() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        h.appState.phase = .idle
        h.client.onAlarmsChanged?(snapshot("1000-0", 1, [.remotePermissionDenied]))
        for _ in 0..<50 { await Task.yield() }
        #expect(h.appState.activeAlarms.isEmpty && h.repairRequests.value == 0)
    }

    /// §6.2 (scan C6, F2 ruling): a crash-restarted helper starts with an empty registry; the app keeps
    /// the old helper's alarms until the new helper's EVIDENCE disproves them — and a permission alarm
    /// is a content kind, so first frames are not enough. The restart re-wires the callbacks (scan B P0.4(5)).
    @Test func crashRestartKeepsTheStickyStateUntilEvidenceArrives() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        h.appState.applyHelperSnapshot(snapshot("1000-0", 1, [.remotePermissionDenied]))

        await h.coordinator.handleXPCCrash()
        #expect(h.client.startCalls.count == 1)
        #expect(h.appState.remoteAudioNotCaptured, "still true after the restart")

        h.client.onAlarmsChanged?(snapshot("2000-0", 1, []))
        for _ in 0..<50 { await Task.yield() }
        #expect(h.appState.remoteAudioNotCaptured, "the new helper's empty registry proves nothing yet")

        h.client.onFirstFrames?(.system, "2000-0")
        for _ in 0..<50 { await Task.yield() }
        #expect(h.appState.remoteAudioNotCaptured, "frames on time prove nothing about a denied tap: they are zeros")

        h.client.onRealAudio?(.system, "2000-0")
        for _ in 0..<50 { await Task.yield() }
        #expect(!h.appState.remoteAudioNotCaptured)
    }

    @Test func threeMissedPollsRaiseHelperUnresponsiveAndAnAnswerClearsIt() async throws {
        let h = try Harness()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        h.client.statusSnapshot = nil
        await h.coordinator.pollHelperStatus(); await h.coordinator.pollHelperStatus()
        #expect(h.appState.activeAlarms[.helperUnresponsive] == nil)
        await h.coordinator.pollHelperStatus()
        #expect(h.appState.activeAlarms[.helperUnresponsive] != nil)
        h.client.statusSnapshot = snapshot("1000-0", 1, [])
        await h.coordinator.pollHelperStatus()
        #expect(h.appState.activeAlarms[.helperUnresponsive] == nil)
    }

    /// The presenter follows the per-kind notify floor (F2 rounds 1–2): a kind notifies at once only
    /// if it has not notified within 2 min — across episodes and clears; the row itself is immediate.
    @Test func presentAlarmsHonoursThePerKindNotifyFloor() async throws {
        let h = try Harness()
        let shown = Harness.Box<[(alarms: [ActiveAlarm], new: [AlarmKind])]>([])
        let coordinator = RecordingCoordinator(
            appState: h.appState, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { _, _ in }, notifyCritical: { _, _ in }, presentTranscript: { _, _ in },
            presentAlarmsUI: { alarms, new in shown.value.append((alarms, new)) }, recordingMicrophone: h.recordingMic)
        h.appState.phase = .recording(since: Date())
        let t0 = Date()
        h.appState.raiseAppAlarm(.diskLow, message: "low", now: t0)
        coordinator.presentAlarms(now: t0)
        #expect(shown.value.count == 1 && shown.value[0].new == [.diskLow])
        coordinator.presentAlarms(now: t0 + 60)
        #expect(shown.value.count == 1, "nothing new, not due")
        coordinator.presentAlarms(now: t0 + 121)
        #expect(shown.value.count == 2 && shown.value[1].new.isEmpty, "re-notify: same alarm, no new kinds")

        h.appState.clearAppAlarm(.diskLow)
        h.appState.raiseAppAlarm(.diskLow, message: "low again", now: t0 + 150)
        coordinator.presentAlarms(now: t0 + 150)
        #expect(shown.value.count == 2, "a new episode inside the floor: the row is up, nothing notifies")
        #expect(h.appState.activeAlarms[.diskLow] != nil)
        coordinator.presentAlarms(now: t0 + 241)
        #expect(shown.value.count == 3)

        h.appState.raiseAppAlarm(.recordingStopped, message: "stopped", now: t0 + 242)
        coordinator.presentAlarms(now: t0 + 242)
        #expect(shown.value.count == 4 && shown.value[3].new == [.recordingStopped], "acknowledgeable kinds are exempt from the floor")
    }

    // MARK: - L9: retry cap on confirmed frames; honest "Resumed"; launch recovery (§8.3–8.5)

    @Test func retryStreakResetsOnlyAfterConfirmedFrames() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        h.coordinator.recoveryConfirmationSeconds = 60
        await h.coordinator.handleXPCCrash()
        #expect(h.coordinator.xpcRetryCount == 1)

        let t0 = Date()
        h.coordinator.noteFirstFrames(track: .mic, helperSessionId: "2000-0", now: t0)
        #expect(h.notified.value.map(\.title) == ["Recording Resumed"])
        h.coordinator.confirmRecoveryHealthy(now: t0 + 30)
        #expect(h.coordinator.xpcRetryCount == 1, "30 s of frames is not yet confirmation")
        h.coordinator.confirmRecoveryHealthy(now: t0 + 60)
        #expect(h.coordinator.xpcRetryCount == 0)
    }

    /// Spec §8.5 (scan C15): "60 s of CONFIRMED frames" — a mic NotDelivering alarm inside the window
    /// means the frames were not confirmed; the streak stays.
    @Test func aMicAlarmDuringTheConfirmationWindowKeepsTheStreak() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        await h.coordinator.handleXPCCrash()
        let t0 = Date()
        h.coordinator.noteFirstFrames(track: .mic, helperSessionId: "2000-0", now: t0)
        h.client.onAlarmsChanged?(CaptureStatusSnapshot(helperSessionId: "2000-0", sequence: 1, isCapturing: true,
            alarms: [ActiveAlarm(kind: .micNotDelivering, raisedAt: t0 + 10, lastNotifiedAt: nil, message: "m", episode: 1)], tracks: []))
        for _ in 0..<50 { await Task.yield() }
        h.coordinator.confirmRecoveryHealthy(now: t0 + 61)
        #expect(h.coordinator.xpcRetryCount == 1)
    }

    /// Gotcha #50 / L9: a helper that crashes on its first sample never delivers frames, so the
    /// streak never resets and the third crash inside the window gives up.
    @Test func firstSampleCrashLoopGivesUpAtTheCap() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        await h.coordinator.handleXPCCrash()
        _ = try h.writeSentinel()
        await h.coordinator.handleXPCCrash()
        #expect(h.coordinator.xpcRetryCount == 2)
        _ = try h.writeSentinel()
        await h.coordinator.handleXPCCrash()
        #expect(h.appState.isIdle)
        #expect(h.criticals.value.map(\.title) == ["Recording Failed"])
    }

    /// A restart that never saw frames (the user stopped first) must not leak into the next recording:
    /// that recording's first frames are not a recovery.
    @Test func aNewRecordingNeverInheritsAnUnconfirmedRestart() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        await h.coordinator.handleXPCCrash()
        h.appState.phase = .idle   // the recording ended before the restarted helper delivered

        // L2/L4 fix round 2, item 1: the new recording's helper reports its first frames DURING start().
        let coordinator = h.coordinator
        h.client.onStart = { coordinator.noteFirstFrames(track: .mic, helperSessionId: "3000-0") }
        await h.coordinator.startRecording(sessionName: "Next", microphoneDeviceId: "mic-1")
        #expect(h.appState.isRecording)
        h.coordinator.noteFirstFrames(track: .mic, helperSessionId: "3000-0")
        #expect(h.notified.value.isEmpty)
    }

    /// Item 1: every end path clears the restart's pending confirmation — frames reported after the
    /// recording ended (a late message, or a relaunch) are not a recovery.
    @Test func aStoppedRestartLeavesNothingArmed() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        await h.coordinator.handleXPCCrash()   // restarted, waiting for frames
        await h.coordinator.stopRecording()    // (the fake's stop fails: the catch path ends it)
        #expect(h.appState.isIdle)
        h.coordinator.noteFirstFrames(track: .mic, helperSessionId: "2000-0")
        #expect(!h.notified.value.contains { $0.title == "Recording Resumed" })
    }

    /// Item 2: a Stop pressed during the restart: frames arriving before the deferred stop runs must
    /// not announce "Resumed" for a recording that is ending.
    @Test func aStopRequestedDuringTheRestartNeverAnnouncesResumed() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        h.client.stopError = FakeCaptureError()
        let coordinator = h.coordinator
        h.client.onStartAsync = {
            await coordinator.stopRecording()   // deferred: recovery is in flight
            coordinator.noteFirstFrames(track: .mic, helperSessionId: "2000-0")
        }
        await h.coordinator.handleXPCCrash()
        #expect(h.client.stopCalls == 1, "the deferred stop ran")
        #expect(!h.notified.value.contains { $0.title == "Recording Resumed" })
    }

    /// Item 3: the not-capturing escalation must not run inside the status-poll task: a Stop deferred
    /// during that restart cancels the poll, and the whole stop + finalize would run CANCELLED.
    @Test func aStopDeferredDuringAPollEscalatedRestartIsNotCancelled() async throws {
        let h = try Harness()
        h.config.update {
            $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path
            $0.engine = .fluidAudio
        }
        h.coordinator.statusPollInterval = .milliseconds(5)
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        defer {
            h.runner.stopChunkRotation()
            h.runner.teardownChunkedPipeline()
        }
        let sequence = Harness.Box<UInt64>(0)
        h.client.statusProvider = {
            sequence.value += 1
            return CaptureStatusSnapshot(helperSessionId: "1000-0", sequence: sequence.value, isCapturing: false, alarms: [], tracks: [])
        }
        let coordinator = h.coordinator
        let stopped = Harness.Box(false)
        h.client.onStartAsync = {
            guard !stopped.value else { return }
            stopped.value = true
            await coordinator.stopRecording()   // deferred: the escalated recovery is in flight
        }
        var waited = 0
        while h.client.stopCalls == 0, waited < 400 { try await Task.sleep(nanoseconds: 5_000_000); waited += 1 }
        #expect(h.client.stopCalls == 1)
        #expect(h.client.stopSawCancellation == false, "the deferred stop ran in a cancelled task")
    }

    // MARK: - L2/L4 fix round 1

    /// Item 1: the 5 s PULL is the source of truth (§6.2): a mic alarm only the pull saw, even one
    /// cleared again before the window ended, voids the confirmation (§8.5).
    @Test func aPulledMicAlarmDuringTheConfirmationWindowKeepsTheStreak() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        await h.coordinator.handleXPCCrash()
        let t0 = Date()
        h.coordinator.noteFirstFrames(track: .mic, helperSessionId: "2000-0", now: t0)
        h.client.statusSnapshot = snapshot("2000-0", 1, [.micNotDelivering])
        await h.coordinator.pollHelperStatus()
        h.client.statusSnapshot = snapshot("2000-0", 2, [])
        await h.coordinator.pollHelperStatus()
        h.coordinator.confirmRecoveryHealthy(now: t0 + 61)
        #expect(h.coordinator.xpcRetryCount == 1)
    }

    /// Item 1: a mic NotDelivering alarm still active when the window ends means the frames were not
    /// confirmed, whenever it was raised.
    @Test func aMicAlarmStillActiveAtTheEndOfTheWindowKeepsTheStreak() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        await h.coordinator.handleXPCCrash()
        h.client.onAlarmsChanged?(snapshot("2000-0", 1, [.micNotDelivering]))
        for _ in 0..<50 { await Task.yield() }
        let t0 = Date()
        h.coordinator.noteFirstFrames(track: .mic, helperSessionId: "2000-0", now: t0)
        h.coordinator.confirmRecoveryHealthy(now: t0 + 61)
        #expect(h.coordinator.xpcRetryCount == 1)
    }

    /// Item 2: first frames can land while `start()` is still awaited (a main-actor stall); the flag is
    /// armed before the start, so "Resumed" is still said and the banner is not reset to "waiting".
    @Test func firstFramesDuringTheRestartStillAnnounceResumed() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        let coordinator = h.coordinator
        h.client.onStart = { coordinator.noteFirstFrames(track: .mic, helperSessionId: "2000-0") }
        await h.coordinator.handleXPCCrash()
        #expect(h.notified.value.map(\.title) == ["Recording Resumed"])
        #expect(h.appState.interruptionWarning == "Recording briefly interrupted. Resumed.")
    }

    @Test func aFailedRestartDoesNotLeaveTheRecoveryArmed() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        h.client.startError = FakeCaptureError()
        await h.coordinator.handleXPCCrash()
        h.appState.phase = .recording(since: Date())   // a later recording, however it began
        h.coordinator.noteFirstFrames(track: .mic, helperSessionId: "3000-0")
        #expect(!h.notified.value.contains { $0.title == "Recording Resumed" })
    }

    /// Items 3, 7, 10: a relaunch resume wires the callbacks BEFORE `start()`, says nothing about
    /// "Resumed" until frames arrive, and then keeps the relaunch's loss wording (the exact gap is the
    /// `recordingResumedWithGap` alarm, L7).
    @Test func aRelaunchResumeWaitsForFramesAndSaysAudioMayHaveBeenLost() async throws {
        let h = try Harness()
        try writeFreshSentinel(h)
        defer {
            h.runner.stopChunkRotation()
            h.runner.teardownChunkedPipeline()
        }
        let wiredAtStart = Harness.Box(false)
        h.client.onStart = { wiredAtStart.value = h.client.onFirstFrames != nil && h.client.onServiceCrash != nil }
        await h.coordinator.recoverAtLaunch()
        #expect(wiredAtStart.value, "a helper reporting during start() must find the callbacks wired")
        #expect(h.appState.isRecording && h.notified.value.isEmpty)
        #expect(h.appState.interruptionWarning == "Recording restarted — waiting for audio…")

        h.coordinator.noteFirstFrames(track: .mic, helperSessionId: "2000-0")
        let resumed = try #require(h.notified.value.first)
        #expect(resumed.title == "Recording Resumed" && resumed.body.contains("Some audio may have been lost"))
        #expect(h.appState.interruptionWarning?.contains("Some audio may have been lost") == true)
    }

    /// Items 2, 3: at launch the phase is not yet `.recording` while `start()` runs; frames arriving then
    /// are still the restart's first frames.
    @Test func relaunchFramesDuringStartAreNotLost() async throws {
        let h = try Harness()
        try writeFreshSentinel(h)
        defer {
            h.runner.stopChunkRotation()
            h.runner.teardownChunkedPipeline()
        }
        let coordinator = h.coordinator
        h.client.onStart = { coordinator.noteFirstFrames(track: .mic, helperSessionId: "2000-0") }
        await h.coordinator.recoverAtLaunch()
        #expect(h.notified.value.map(\.title) == ["Recording Resumed"])
        #expect(h.appState.interruptionWarning?.contains("waiting for audio") == false)
    }

    /// Item 10: the confirmation is scheduled by the first frames themselves.
    @Test func theScheduledConfirmationResetsTheStreak() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        h.coordinator.recoveryConfirmationSeconds = 0
        await h.coordinator.handleXPCCrash()
        #expect(h.coordinator.xpcRetryCount == 1)
        h.coordinator.noteFirstFrames(track: .mic, helperSessionId: "2000-0")
        var waited = 0
        while h.coordinator.xpcRetryCount != 0, waited < 200 { try await Task.sleep(nanoseconds: 5_000_000); waited += 1 }
        #expect(h.coordinator.xpcRetryCount == 0)
    }

    /// Item 10: "Resumed" waits for the MIC: remote frames alone do not prove the user is recorded.
    @Test func systemFirstFramesDoNotAnnounceResumed() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        await h.coordinator.handleXPCCrash()
        h.coordinator.noteFirstFrames(track: .system, helperSessionId: "2000-0")
        #expect(h.notified.value.isEmpty)
        #expect(h.appState.interruptionWarning == "Recording restarted — waiting for audio…")
    }

    private func notCapturing(_ id: String, _ sequence: UInt64) -> CaptureStatusSnapshot {
        CaptureStatusSnapshot(helperSessionId: id, sequence: sequence, isCapturing: false, alarms: [], tracks: [])
    }

    /// Item 5 (defense in depth): a helper that answers but is not capturing is a dead recording. Two
    /// consecutive such polls take the crash-recovery path, and the evidence is recorded.
    @Test func twoNotCapturingPollsEscalateToCrashRecovery() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        h.client.statusSnapshot = notCapturing("1000-0", 1)
        await h.coordinator.pollHelperStatus()
        #expect(h.client.startCalls.isEmpty, "one poll is not enough")
        h.client.statusSnapshot = notCapturing("1000-0", 2)
        await h.coordinator.pollHelperStatus()
        // Dispatched outside the poll task (fix round 2, item 3): let it run.
        for _ in 0..<50 where h.client.startCalls.isEmpty { await Task.yield() }
        #expect(h.client.startCalls.count == 1, "restarted like an XPC crash")
        #expect(h.client.retryEvents.count == 1, "under the same retry cap")
        #expect(h.client.recordedEvents.contains { $0.kind == .xpcInterruption && $0.detail["classification"] == "not capturing" })
    }

    @Test func oneNotCapturingPollFollowedByCapturingDoesNotEscalate() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        h.client.statusSnapshot = notCapturing("1000-0", 1)
        await h.coordinator.pollHelperStatus()
        h.client.statusSnapshot = snapshot("1000-0", 2, [])
        await h.coordinator.pollHelperStatus()
        h.client.statusSnapshot = notCapturing("1000-0", 3)
        await h.coordinator.pollHelperStatus()
        #expect(h.client.startCalls.isEmpty)
    }

    @Test func notCapturingPollsNeverEscalateWhileARestartOrStopIsInFlight() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        h.coordinator.recoveryInFlight = true
        h.client.statusSnapshot = notCapturing("1000-0", 1)
        await h.coordinator.pollHelperStatus()
        h.client.statusSnapshot = notCapturing("1000-0", 2)
        await h.coordinator.pollHelperStatus()
        h.coordinator.recoveryInFlight = false
        h.coordinator.stopInFlight = true
        h.client.statusSnapshot = notCapturing("1000-0", 3)
        await h.coordinator.pollHelperStatus()
        h.client.statusSnapshot = notCapturing("1000-0", 4)
        await h.coordinator.pollHelperStatus()
        #expect(h.client.startCalls.isEmpty)
    }

    /// Item 9 (§6.3 "every 2 min while any alarm is active"): an alarm that outlives the recording keeps
    /// being presented while idle; the timer exists only while such an alarm does.
    @Test func anIdleAlarmIsPresentedOnTheIdleTimerUntilItIsAcknowledged() async throws {
        let h = try Harness()
        let shown = Harness.Box<[[AlarmKind]]>([])
        let coordinator = RecordingCoordinator(
            appState: h.appState, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { _, _ in }, notifyCritical: { _, _ in }, presentTranscript: { _, _ in },
            presentAlarmsUI: { due, _ in shown.value.append(due.map(\.kind)) }, recordingMicrophone: h.recordingMic)
        coordinator.idleRealarmInterval = .milliseconds(20)
        #expect(!coordinator.idleRealarmActive, "no alarm, no timer")

        h.appState.raiseAppAlarm(.recordingStopped, message: "stopped")
        var waited = 0
        while shown.value.isEmpty, waited < 200 { try await Task.sleep(nanoseconds: 5_000_000); waited += 1 }
        #expect(shown.value.first == [.recordingStopped])

        // Fix round 2, item 5: an acknowledgeable past event is presented ONCE while idle; with nothing
        // more to say the timer ends by itself (no idle wakeups).
        waited = 0
        while coordinator.idleRealarmActive, waited < 200 { try await Task.sleep(nanoseconds: 5_000_000); waited += 1 }
        #expect(!coordinator.idleRealarmActive, "presented once: nothing more to say")
        #expect(shown.value.count == 1)
        h.appState.acknowledge(.recordingStopped)
        #expect(h.appState.activeAlarms.isEmpty)
    }

    /// Fix round 2, item 5 (owner ruling): while NOT recording, an idle alarm re-notifies at 2 min, then
    /// 10 min, then at most hourly — mid-call urgency is noise all day. The injected clock drives it.
    @Test func idleAlarmsBackOffTwoThenTenThenSixtyMinutes() async throws {
        let h = try Harness()
        let state = AppState()   // its own: the Harness coordinator must not present into this clock
        let shown = Harness.Box<Int>(0)
        let coordinator = RecordingCoordinator(
            appState: state, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { _, _ in }, notifyCritical: { _, _ in }, presentTranscript: { _, _ in },
            presentAlarmsUI: { _, _ in shown.value += 1 }, recordingMicrophone: h.recordingMic)
        let t0 = Date()
        state.raiseAppAlarm(.crashProtectionOff, message: "off", now: t0)
        coordinator.presentAlarms(now: t0)
        #expect(shown.value == 1)
        coordinator.presentAlarms(now: t0 + 119);  #expect(shown.value == 1)
        coordinator.presentAlarms(now: t0 + 120);  #expect(shown.value == 2, "2 min")
        coordinator.presentAlarms(now: t0 + 719);  #expect(shown.value == 2)
        coordinator.presentAlarms(now: t0 + 720);  #expect(shown.value == 3, "then 10 min")
        coordinator.presentAlarms(now: t0 + 4319); #expect(shown.value == 3)
        coordinator.presentAlarms(now: t0 + 4320); #expect(shown.value == 4, "then hourly")
        coordinator.presentAlarms(now: t0 + 7920); #expect(shown.value == 5)
    }

    /// L round 5, item 11: a recording start is in flight — and a hand-over must wait — from the very
    /// top of `startRecording` until it returns, whatever the outcome.
    @Test func startInFlightCoversTheWholeStart() async throws {
        let h = try Harness()
        h.config.update {
            $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path
            $0.engine = .fluidAudio
        }
        let coordinator = h.coordinator
        let duringStart = Harness.Box<Bool?>(nil)
        h.client.onStart = { duringStart.value = coordinator.isStartInFlight }
        #expect(!coordinator.isStartInFlight)
        await coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        defer {
            h.runner.stopChunkRotation()
            h.runner.teardownChunkedPipeline()
        }
        #expect(duringStart.value == true && !coordinator.isStartInFlight)

        h.appState.phase = .idle
        h.client.startError = FakeCaptureError()
        await coordinator.startRecording(sessionName: "Again", microphoneDeviceId: "mic-1")
        #expect(!coordinator.isStartInFlight, "cleared on the failure path too")
    }

    /// L round 7, item 3: the Start is announced SYNCHRONOUSLY when the dialog commits, so no main-actor
    /// turn between the dialog closing and `startRecording` counts as idle; `startRecording` takes it over.
    @Test func anAnnouncedStartIsInFlightFromTheFirstTurn() async throws {
        let h = try Harness()
        h.config.update {
            $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path
            $0.engine = .fluidAudio
        }
        h.coordinator.announceStart()
        #expect(h.coordinator.isStartInFlight, "from this very turn")
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        defer {
            h.runner.stopChunkRotation()
            h.runner.teardownChunkedPipeline()
        }
        #expect(h.appState.isRecording && !h.coordinator.isStartInFlight)
    }

    /// L round 7, item 5: the phase is still `.idle` while the first start awaits the helper, so the
    /// `isIdle` guard alone let a second start through. Exactly one helper start; the loser changes nothing.
    @Test func twoConcurrentStartsStartTheHelperOnce() async throws {
        let h = try Harness()
        h.config.update {
            $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path
            $0.engine = .fluidAudio
        }
        let coordinator = h.coordinator
        let second = Harness.Box<Task<Void, Never>?>(nil)
        h.client.onStartAsync = {
            guard second.value == nil else { return }
            second.value = Task { await coordinator.startRecording(sessionName: "Second", microphoneDeviceId: "mic-2") }
            for _ in 0..<50 { await Task.yield() }
        }
        await coordinator.startRecording(sessionName: "First", microphoneDeviceId: "mic-1")
        await second.value?.value
        defer {
            h.runner.stopChunkRotation()
            h.runner.teardownChunkedPipeline()
        }
        #expect(h.client.startCalls.count == 1)
        #expect(h.client.startCalls.first?.microphoneDeviceId == "mic-1")
        #expect(h.appState.isRecording)
        #expect(RecordingSentinel.read(directory: h.tmp)?.micDeviceUID == "mic-1", "the loser wrote nothing")
    }

    // MARK: - L5: stop vs crash, double start, post-start failure (§8.6)

    /// L6: the trailing invalidation of a stop lands mid-stop; the stop path owns the teardown.
    @Test func aCrashDuringStopIsIgnoredByTheCrashHandler() async throws {
        let h = try Harness(); _ = try h.writeSentinel(); h.appState.phase = .recording(since: Date())
        h.client.stopError = FakeCaptureError()
        h.client.onStop = { await h.coordinator.handleXPCCrash() }
        await h.coordinator.stopRecording()
        #expect(h.client.startCalls.isEmpty, "the stop path owns the teardown; no restart")
        #expect(h.appState.isIdle)
    }

    /// L7: a second Start while the first is still setting up is ignored, not queued.
    @Test func aSecondStartWhileOneIsInFlightIsIgnored() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }   // never the real ~/Documents/Recordings
        defer {
            h.runner.stopChunkRotation()
            h.runner.teardownChunkedPipeline()
        }
        h.client.onStart = { Task { await h.coordinator.startRecording(sessionName: "b", microphoneDeviceId: nil) } }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.client.startCalls.count == 1)
        #expect(RecordingSentinel.read(directory: h.tmp)?.sessionName == "a")
        #expect(!h.coordinator.isStartInFlight)
    }

    /// L8: any failure after a successful helper start runs a bounded stop before reporting.
    @Test func aFailureAfterAStartedHelperStopsTheHelper() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        h.runner.failSetupForTesting = true   // R0 seam: setupChunkedPipeline throws
        h.client.stopResult = AudioPaths(systemAudio: h.tmp.appendingPathComponent("a.wav"), micAudio: h.tmp.appendingPathComponent("a_mic.wav"))
        let markedAtStop = Harness.Box<String??>(nil)
        let recordingMic = h.recordingMic
        h.client.onStop = { markedAtStop.value = recordingMic.current }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "mic-1")
        #expect(h.client.stopCalls == 1)
        #expect(markedAtStop.value == .some("mic-1"), "the mic marker is released only after the helper let go (#192)")
        #expect(h.recordingMic.current == .none)
        #expect(h.appState.isIdle)
        #expect(h.notified.value.map(\.title) == ["Recording Failed"])
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
    }

    /// A helper start that fails never reached the helper's capture: nothing to stop.
    @Test func aFailedHelperStartIsNotStopped() async throws {
        let h = try Harness()
        h.client.startError = FakeCaptureError()
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(h.client.stopCalls == 0)
        #expect(h.notified.value.map(\.title) == ["Recording Failed"])
    }

    /// Ledger note (L5): a crash reported while `start()` is awaited arrives while the phase is still
    /// `.idle`. It must not be dropped (the client reports it once per capture generation): it is handled
    /// as soon as the recording is up.
    @Test func aCrashDuringTheStartIsHandledOnceTheRecordingIsUp() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer {
            h.runner.stopChunkRotation()
            h.runner.teardownChunkedPipeline()
        }
        let client = h.client
        let fired = Harness.Box(false)
        client.onStartAsync = {
            guard !fired.value else { return }
            fired.value = true
            client.onServiceCrash?()                      // the helper dies while start() is awaited
            await Harness.until { h.coordinator.crashDuringStart }   // noted, the phase still .idle
        }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        for _ in 0..<50 where client.startCalls.count < 2 { await Task.yield() }
        #expect(client.startCalls.count == 2, "the recording's start, then the crash restart")
        #expect(client.retryEvents.count == 1)
        #expect(h.appState.isRecording)
    }

    /// A crash during a start that then FAILS is moot: the failure path ends it, and the next recording
    /// never inherits it.
    @Test func aCrashDuringAFailedStartIsNotInheritedByTheNextRecording() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer {
            h.runner.stopChunkRotation()
            h.runner.teardownChunkedPipeline()
        }
        let client = h.client
        client.startError = FakeCaptureError()
        client.onStartAsync = {
            guard client.startCalls.count == 1 else { return }
            client.onServiceCrash?()
            await Harness.until { h.coordinator.crashDuringStart }
        }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        client.startError = nil
        await h.coordinator.startRecording(sessionName: "b", microphoneDeviceId: nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(client.startCalls.count == 2 && client.retryEvents.isEmpty, "no restart for the failed start's crash")
        #expect(h.appState.isRecording)
    }

    /// L round 5, item 15: a failed stop whose sentinel is MISSING still salvages from the live
    /// pipeline's own session location — never "no recorded audio" while chunks are on disk.
    @Test func aFailedStopWithoutTheSentinelSalvagesFromTheLivePipeline() async throws {
        let h = try Harness()
        h.config.update {
            $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path
            $0.engine = .fluidAudio
        }
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        defer {
            h.runner.stopChunkRotation()
            h.runner.teardownChunkedPipeline()
        }
        let rotator = try #require(h.runner.chunkRotator)
        let sentinel = try #require(RecordingSentinel.read(directory: h.tmp))
        let outDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try Harness.headerOnlyWAV().write(to: outDir.appendingPathComponent(rotator.currentBaseName + ".wav"))
        RecordingSentinel.delete(directory: h.tmp)   // e.g. deleted mid-recording
        h.client.stopError = FakeCaptureError()

        await h.coordinator.stopRecording()

        let critical = try #require(h.criticals.value.first)
        #expect(!critical.body.contains("no recorded audio"), "\(critical.body)")
    }

    // MARK: - L round 4

    private func coordinatorShowing(_ h: Harness, _ state: AppState, repairPresents: Bool,
                                    into shown: Harness.Box<[(due: [AlarmKind], new: [AlarmKind])]>) -> RecordingCoordinator {
        RecordingCoordinator(
            appState: state, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { _, _ in }, notifyCritical: { _, _ in }, presentTranscript: { _, _ in },
            onSystemAudioPermissionDenied: { repairPresents },
            presentAlarmsUI: { due, new in shown.value.append((due.map(\.kind), new)) }, recordingMicrophone: h.recordingMic)
    }

    /// Item 4 (IMPORTANT): the repair window declines (nothing missing app-side — `remoteCantConfirm`,
    /// or #220's coreaudiod refusal although granted — or its snooze): the alarm window presents at
    /// once. Never silent for 2 min mid-call.
    @Test func aPermissionAlarmTheRepairWindowDeclinesIsPresentedAtOnce() async throws {
        let h = try Harness()
        let state = AppState()
        let shown = Harness.Box<[(due: [AlarmKind], new: [AlarmKind])]>([])
        let coordinator = coordinatorShowing(h, state, repairPresents: false, into: shown)
        state.phase = .recording(since: Date())
        state.raiseAppAlarm(.diskLow, message: "low")   // (any other active alarm)
        coordinator.presentAlarms()
        state.applyHelperSnapshot(snapshot("1000-0", 1, [.remoteCantConfirm]))
        coordinator.presentAlarms()
        for _ in 0..<50 where shown.value.count < 2 { await Task.yield() }
        #expect(shown.value.count == 2 && shown.value[1].due == [.remoteCantConfirm] && shown.value[1].new == [.remoteCantConfirm])
        #expect(state.activeAlarms[.remoteCantConfirm]?.lastNotifiedAt != nil, "a presentation that happened")
    }

    /// Item 4: the repair window did present — no second window or notification for the same alarm.
    @Test func aPermissionAlarmTheRepairWindowShowsIsNotShownTwice() async throws {
        let h = try Harness()
        let state = AppState()
        let shown = Harness.Box<[(due: [AlarmKind], new: [AlarmKind])]>([])
        let coordinator = coordinatorShowing(h, state, repairPresents: true, into: shown)
        state.phase = .recording(since: Date())
        state.applyHelperSnapshot(snapshot("1000-0", 1, [.remotePermissionDenied]))
        coordinator.presentAlarms()
        for _ in 0..<50 { await Task.yield() }
        #expect(shown.value.isEmpty)
        #expect(state.activeAlarms[.remotePermissionDenied]?.lastNotifiedAt != nil, "the repair window's presentation counts")
    }

    /// L round 5, item 18: the repair path may take a macOS prompt's ~10 s, or HANG (an unbounded
    /// permission refresh). After 3 s the alarm's own notification goes out — no window, the repair
    /// window may still open — and the normal re-notify cadence resumes.
    @Test func aRepairCheckThatNeverAnswersStillNotifiesWithinTheCap() async throws {
        let h = try Harness()
        let state = AppState()
        let shown = Harness.Box<[(due: [AlarmKind], new: [AlarmKind])]>([])
        let notified = Harness.Box<[AlarmKind]>([])
        let coordinator = RecordingCoordinator(
            appState: state, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { _, _ in }, notifyCritical: { _, _ in }, presentTranscript: { _, _ in },
            onSystemAudioPermissionDenied: { try? await Task.sleep(for: .seconds(3600)); return false },   // never answers
            presentAlarmsUI: { due, new in shown.value.append((due.map(\.kind), new)) },
            notifyAlarm: { notified.value.append($0.kind) },
            recordingMicrophone: h.recordingMic)
        coordinator.repairOutcomeCap = .milliseconds(20)
        state.phase = .recording(since: Date())
        state.applyHelperSnapshot(snapshot("1000-0", 1, [.remotePermissionDenied]))
        coordinator.presentAlarms()
        #expect(notified.value.isEmpty, "the repair window gets its chance first")
        var waited = 0
        while notified.value.isEmpty, waited < 200 { try await Task.sleep(nanoseconds: 5_000_000); waited += 1 }
        #expect(notified.value == [.remotePermissionDenied])
        #expect(shown.value.isEmpty, "notification only: the repair window may still open")
        let stamped = try #require(state.activeAlarms[.remotePermissionDenied]?.lastNotifiedAt)
        coordinator.presentAlarms(now: stamped + 121)
        #expect(shown.value.count == 1, "the normal re-notify cadence resumed")
    }

    /// Item 6: at recording start only live conditions are presented again — a past event is not.
    @Test func pastEventsAreNotRepresentedAtRecordingStart() async throws {
        let h = try Harness()
        let state = AppState()
        let shown = Harness.Box<[(due: [AlarmKind], new: [AlarmKind])]>([])
        let coordinator = coordinatorShowing(h, state, repairPresents: true, into: shown)
        state.raiseAppAlarm(.recordingStopped, message: "stopped")
        state.raiseAppAlarm(.crashProtectionOff, message: "off")
        coordinator.presentAlarms()
        state.phase = .recording(since: Date())
        coordinator.presentCarriedAlarmsAtRecordingStart()
        #expect(shown.value.last?.due == [.crashProtectionOff])
    }

    /// Item 7: a past event is presented once, never re-notified every 2 min mid-call.
    @Test func anAcknowledgeablePastEventNeverRenotifiesMidCall() async throws {
        let h = try Harness()
        let state = AppState()
        let shown = Harness.Box<[(due: [AlarmKind], new: [AlarmKind])]>([])
        let coordinator = coordinatorShowing(h, state, repairPresents: true, into: shown)
        state.phase = .recording(since: Date())
        let t0 = Date()
        state.raiseAppAlarm(.recordingResumedWithGap, message: "gap", now: t0)
        coordinator.presentAlarms(now: t0)
        coordinator.presentAlarms(now: t0 + 121)
        coordinator.presentAlarms(now: t0 + 3600)
        #expect(shown.value.count == 1)
    }

    /// Item 8: the escalation is dispatched outside the poll task; if the recording ended meanwhile,
    /// nothing is restarted.
    @Test func aNotCapturingEscalationIsDroppedIfTheRecordingEnded() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        h.client.statusSnapshot = CaptureStatusSnapshot(helperSessionId: "1000-0", sequence: 1, isCapturing: false, alarms: [], tracks: [])
        await h.coordinator.pollHelperStatus()
        h.client.statusSnapshot = CaptureStatusSnapshot(helperSessionId: "1000-0", sequence: 2, isCapturing: false, alarms: [], tracks: [])
        await h.coordinator.pollHelperStatus()
        h.appState.phase = .idle   // stopped before the dispatched recovery ran
        for _ in 0..<50 { await Task.yield() }
        #expect(h.client.startCalls.isEmpty)
    }

    /// Item 9: the idle backoff CONTINUES after a recording — no extra 2-min step, and mid-call
    /// presentations don't count toward it.
    @Test func theIdleBackoffContinuesAfterARecording() async throws {
        let h = try Harness()
        let state = AppState()
        let shown = Harness.Box<[(due: [AlarmKind], new: [AlarmKind])]>([])
        let coordinator = coordinatorShowing(h, state, repairPresents: true, into: shown)
        let t0 = Date()
        state.raiseAppAlarm(.crashProtectionOff, message: "off", now: t0)
        coordinator.presentAlarms(now: t0)          // 1st
        coordinator.presentAlarms(now: t0 + 120)    // 2nd: next gap is 10 min
        state.phase = .recording(since: Date())
        coordinator.presentCarriedAlarmsAtRecordingStart(now: t0 + 200)   // mid-call: not a backoff step
        state.phase = .idle
        let before = shown.value.count
        coordinator.presentAlarms(now: t0 + 200 + 599)
        #expect(shown.value.count == before, "still on the 10-min step, not back to 2 min")
        coordinator.presentAlarms(now: t0 + 800)
        #expect(shown.value.count == before + 1)
        coordinator.presentAlarms(now: t0 + 800 + 3599)
        #expect(shown.value.count == before + 1, "then hourly")
    }

    /// L round 3, item 2: an alarm raised while idle is presented AT ONCE (not at the first 2-min tick),
    /// exactly once per raise — that presentation counts toward the backoff.
    @Test func anAlarmRaisedWhileIdleIsPresentedAtOnceThenBacksOff() async throws {
        let h = try Harness()
        let state = AppState()
        let shown = Harness.Box<[(due: [AlarmKind], new: [AlarmKind])]>([])
        let coordinator = RecordingCoordinator(
            appState: state, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { _, _ in }, notifyCritical: { _, _ in }, presentTranscript: { _, _ in },
            presentAlarmsUI: { due, new in shown.value.append((due.map(\.kind), new)) }, recordingMicrophone: h.recordingMic)
        let t0 = Date()
        state.raiseAppAlarm(.crashProtectionOff, message: "off", now: t0)
        for _ in 0..<50 where shown.value.isEmpty { await Task.yield() }
        #expect(shown.value.count == 1 && shown.value[0].new == [.crashProtectionOff], "at once, with its window")
        for _ in 0..<50 { await Task.yield() }
        #expect(shown.value.count == 1, "exactly once")
        coordinator.presentAlarms(now: t0 + 110)
        #expect(shown.value.count == 1)
        coordinator.presentAlarms(now: t0 + 125)
        #expect(shown.value.count == 2, "then the 2-min backoff step: the raise's presentation counted")

        // A new raise of the same kind (a new episode) is presented at once again.
        state.clearAppAlarm(.crashProtectionOff)
        for _ in 0..<50 { await Task.yield() }
        state.raiseAppAlarm(.crashProtectionOff, message: "off again")
        for _ in 0..<50 where shown.value.count == 2 { await Task.yield() }
        #expect(shown.value.count == 3 && shown.value[2].new == [.crashProtectionOff])
    }

    /// Fix round 2, item 5: starting a recording while an idle alarm is active presents it again at once.
    @Test func startingARecordingPresentsAnActiveIdleAlarmAgain() async throws {
        let h = try Harness()
        h.config.update {
            $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path
            $0.engine = .fluidAudio
        }
        let shown = Harness.Box<[(due: [AlarmKind], new: [AlarmKind])]>([])
        let coordinator = RecordingCoordinator(
            appState: h.appState, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { _, _ in }, notifyCritical: { _, _ in }, presentTranscript: { _, _ in },
            presentAlarmsUI: { due, new in shown.value.append((due.map(\.kind), new)) }, recordingMicrophone: h.recordingMic)
        h.appState.raiseAppAlarm(.crashProtectionOff, message: "off")
        coordinator.presentAlarms()
        #expect(shown.value.count == 1)

        await coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        defer {
            h.runner.stopChunkRotation()
            h.runner.teardownChunkedPipeline()
        }
        #expect(h.appState.isRecording)
        #expect(shown.value.count == 2 && shown.value.last?.due == [.crashProtectionOff])
        #expect(shown.value.last?.new == [.crashProtectionOff], "window and notification again")
    }

    @Test func theIdleTimerStopsWhenTheAlarmClears() async throws {
        let h = try Harness()
        h.coordinator.idleRealarmInterval = .milliseconds(20)
        h.appState.raiseAppAlarm(.crashProtectionOff, message: "off")
        var waited = 0
        while !h.coordinator.idleRealarmActive, waited < 200 { try await Task.sleep(nanoseconds: 5_000_000); waited += 1 }
        #expect(h.coordinator.idleRealarmActive)
        h.appState.clearAppAlarm(.crashProtectionOff)
        waited = 0
        while h.coordinator.idleRealarmActive, waited < 200 { try await Task.sleep(nanoseconds: 5_000_000); waited += 1 }
        #expect(!h.coordinator.idleRealarmActive)
    }

    /// A sentinel the crashed app refreshed 10 s ago, on this boot: the relaunch resumes it (L7).
    private func writeFreshSentinel(_ h: Harness) throws {
        var sentinel = try h.writeSentinel()
        sentinel.lastAliveAt = Date().addingTimeInterval(-10)
        sentinel.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(sentinel, directory: h.tmp)
    }

    // MARK: - L1 fix round 1: serialized crash recovery

    /// CRITICAL: the restarted helper dies during `start()` (a crash reported while recovery #1 is
    /// suspended) and the start then fails. The second crash must be queued, not run concurrently:
    /// one restart, one retry event, one "Recording Failed", and a consistent idle end state.
    @Test func aCrashDuringTheRestartIsQueuedNotRunConcurrently() async throws {
        let h = try Harness()
        h.config.update {
            $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path
            $0.engine = .fluidAudio
        }
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        defer {
            h.runner.stopChunkRotation()
            h.runner.teardownChunkedPipeline()
        }
        let client = h.client, runner = h.runner
        client.onStart = { client.onServiceCrash?() }   // the restarted helper dies during start()…
        client.startError = FakeCaptureError()          // …and the start fails
        let pipelineAliveAtCaptureEnded = Harness.Box<Bool?>(nil)
        client.onCaptureEnded = { pipelineAliveAtCaptureEnded.value = runner.chunkProcessor != nil }

        await h.coordinator.handleXPCCrash()
        for _ in 0..<200 { await Task.yield() }

        #expect(h.criticals.value.map(\.title) == ["Recording Failed"])
        #expect(client.startCalls.count == 2, "the recording's start + exactly one restart")
        #expect(client.retryEvents.count == 1)
        #expect(h.appState.isIdle && client.captureEndedCalls == 1)
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
        // (b): detection disarmed FIRST, before the salvage's awaits (the pipeline is still up then).
        #expect(pipelineAliveAtCaptureEnded.value == true)
    }

    /// L round 5, item 10 (IMPORTANT): a queued crash event is a duplicate or stale (an interruption
    /// plus an invalidation for the same death) when the restarted helper is capturing. Re-running
    /// recovery would `start()` a capturing helper, fail, and end a healthy recording as "Failed".
    @Test func aStaleQueuedCrashIsDroppedWhileTheHelperCaptures() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        let client = h.client, coordinator = h.coordinator
        let starts = Harness.Box(0)
        client.onStart = {
            starts.value += 1
            if starts.value > 1 { client.startError = FakeCaptureError() }   // "capture already in progress"
            client.isCapturingResult = true
        }
        let fired = Harness.Box(false)
        client.onStartAsync = {
            guard !fired.value else { return }
            fired.value = true
            await coordinator.handleXPCCrash()   // the duplicate event for the same death
        }

        await h.coordinator.handleXPCCrash()

        #expect(h.criticals.value.isEmpty && h.appState.isRecording, "the healthy recording goes on")
        #expect(starts.value == 1 && h.client.retryEvents.count == 1)
    }

    /// L round 7, item 2 (IMPORTANT): a Stop pressed during the queued-crash `isCapturing` check must not
    /// race a restart (helper capturing, app idle, sentinel gone: a silent recording with the mic on).
    /// It takes the deferred-stop path; exactly one clean stop, no restart.
    @Test func aStopDuringTheQueuedCrashCheckNeverRacesARestart() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        let client = h.client, coordinator = h.coordinator
        let fired = Harness.Box(false)
        client.onStartAsync = {
            guard !fired.value else { return }
            fired.value = true
            await coordinator.handleXPCCrash()   // queued during the restart
        }
        let stopTask = Harness.Box<Task<Void, Never>?>(nil)
        client.onIsCapturing = {
            stopTask.value = Task { await coordinator.stopRecording() }   // the user presses Stop now
            for _ in 0..<20 { await Task.yield() }
        }
        client.onStop = { for _ in 0..<200 { await Task.yield() } }   // …and the stop is still in flight

        await coordinator.handleXPCCrash()
        await stopTask.value?.value
        for _ in 0..<50 { await Task.yield() }

        #expect(client.startCalls.count == 1, "no restart raced the Stop")
        #expect(client.stopCalls == 1)
        #expect(!h.appState.isRecording)
    }

    /// A crash queued while a restart SUCCEEDS runs next, and counts toward the cap.
    @Test func aCrashQueuedDuringASuccessfulRestartRunsNext() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        let coordinator = h.coordinator
        let fired = Harness.Box(false)
        h.client.onStartAsync = {
            guard !fired.value else { return }
            fired.value = true
            await coordinator.handleXPCCrash()   // reported while recovery #1 is still in flight
        }

        await h.coordinator.handleXPCCrash()

        #expect(h.client.startCalls.count == 2, "the queued crash restarted once more")
        #expect(h.client.retryEvents.count == 2 && h.coordinator.xpcRetryCount == 2)
        #expect(h.appState.isRecording && h.criticals.value.isEmpty)
    }

    @Test func firstFramesOutsideARecoveryDoNotAnnounceResumed() async throws {
        let h = try Harness()
        h.appState.phase = .recording(since: Date())
        h.coordinator.noteFirstFrames(track: .mic, helperSessionId: "1000-0")
        #expect(h.notified.value.isEmpty)
    }

    /// Flow A at launch: the helper is still capturing → re-attach, restore its alarm state, no salvage.
    @Test func recoverAtLaunchReattachesToACapturingHelper() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.client.isCapturingResult = true
        h.client.statusSnapshot = CaptureStatusSnapshot(helperSessionId: "1000-0", sequence: 1, isCapturing: true,
            alarms: [ActiveAlarm(kind: .micDigitalSilence, raisedAt: Date(), lastNotifiedAt: nil, message: "m", episode: 1)], tracks: [])
        await h.coordinator.recoverAtLaunch()
        for _ in 0..<50 { await Task.yield() }
        #expect(h.appState.isRecording && h.client.startCalls.isEmpty)
        #expect(h.client.launchRecoveries.first?["flow"] == "A")
        // No start() ran in this process, so crash detection must be armed explicitly (C1).
        #expect(h.client.captureReattachedCalls == 1 && h.client.captureEndedCalls == 0)
        // L1 fix round 1, item 2: armed BEFORE the ping — an interruption between the two is not lost.
        #expect(h.client.armedAtPing == true)
        // L round 5, item 12: and wired before it, so a crash reported during the ping is heard.
        #expect(h.client.wiredAtPing == true)
        #expect(h.appState.activeAlarms[.micDigitalSilence] != nil)
        #expect(RecordingSentinel.read(directory: h.tmp) != nil)
    }

    /// Launch recovery that ends without a capture — nothing to recover, or the restart failed —
    /// disarms crash detection (C1), so a later helper idle-exit is never read as this recording's crash.
    @Test func recoverAtLaunchWithNothingToRecoverEndsTheCapture() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()   // helper not capturing, no session.json, no audio on disk
        await h.coordinator.recoverAtLaunch()
        #expect(h.appState.isIdle && h.client.startCalls.isEmpty)
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
        #expect(h.client.captureEndedCalls == 1)
    }

    /// L7: a resume whose restart fails is salvaged and says the recording STOPPED — never a silent end.
    @Test func recoverAtLaunchWhoseRestartFailsEndsTheCapture() async throws {
        let h = try Harness()
        try writeFreshSentinel(h)
        h.client.startError = FakeCaptureError()
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.count == 1)
        #expect(h.appState.isIdle && h.appState.activeAlarms[.recordingStopped] != nil)
        #expect(h.client.captureEndedCalls == 1)
        #expect(h.recordingMic.current == .none, "the resume's mic marker is released")
        #expect(RecordingSentinel.read(directory: h.tmp) == nil, "deleted once the salvage ran")
    }

    @Test func failedStartReleasesTheRecordingMic() async throws {
        let h = try Harness()
        h.client.startError = FakeCaptureError()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        #expect(h.recordingMic.current == .none, "a failed start left the mic marked in use — its meter stays off for good")
    }

    @Test func recordingThatDiesInRecoveryReleasesTheRecordingMic() async throws {
        let h = try Harness()
        h.recordingMic.set("mic-1")
        _ = try h.writeSentinel()
        h.client.startError = FakeCaptureError()   // restart fails → recording ends without stopRecording()

        await h.coordinator.handleXPCCrash()

        #expect(h.appState.isIdle)
        #expect(h.recordingMic.current == .none, "the dead recording's mic stayed marked in use")
    }

    @Test func manualSwitchMarksTheNewMicBeforeTheHelperOpensIt() async throws {
        let h = try Harness()
        _ = try h.writeSentinel(micDeviceUID: "mic-1")
        h.appState.phase = .recording(since: Date())
        h.recordingMic.set("mic-1")
        let recordingMic = h.recordingMic
        var seenAtSwitch: String??
        h.client.onUpdateMicrophone = { seenAtSwitch = recordingMic.current }

        try await h.coordinator.switchMicrophone(to: "mic-2")

        #expect(h.client.micUpdates == ["mic-2"])
        #expect(seenAtSwitch == .some("mic-2"), "a meter could open the new mic while the helper was opening it")
        #expect(h.recordingMic.current == .some("mic-2"), "the switcher would meter the mic being recorded")
        #expect(h.coordinator.helperMicId == "mic-2")
        // A crash restart must resume on the mic the user switched to, not the one they left.
        #expect(RecordingSentinel.read(directory: h.tmp)?.micDeviceUID == "mic-2")
    }

    @Test func switchThatCannotUpdateTheSentinelSaysSo() async throws {
        // The switch works, but the recovery file can't be rewritten (disk full, permissions): a crash
        // restart would resume on the mic the user left. That must not happen silently.
        let h = try Harness()
        _ = try h.writeSentinel(micDeviceUID: "mic-1")
        h.appState.phase = .recording(since: Date())
        h.recordingMic.set("mic-1")
        let sentinelFile = h.tmp.appendingPathComponent("recording.json").path
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: sentinelFile)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: h.tmp.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.tmp.path)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sentinelFile)
        }

        try await h.coordinator.switchMicrophone(to: "mic-2")

        #expect(h.recordingMic.current == .some("mic-2"), "the switch itself should still have gone through")
        #expect(RecordingSentinel.read(directory: h.tmp)?.micDeviceUID == "mic-1")   // precondition: write failed
        #expect(h.notified.value.map { $0.title } == ["Recovery File Not Updated"], "a stale recovery mic went unreported")
    }

    @Test func successfulSwitchWhileTheRecordingEndsRaisesNoFalseAlarm() async throws {
        // Stop lands while the helper is switching; the switch then succeeds. The recording ended
        // normally — its recovery file is gone for a good reason — so no "Recovery File Not Updated".
        let h = try Harness()
        _ = try h.writeSentinel(micDeviceUID: "mic-1")
        h.appState.phase = .recording(since: Date())
        h.recordingMic.set("mic-1")
        let appState = h.appState
        let tmp = h.tmp
        h.client.onUpdateMicrophone = {   // what Stop does, in the same synchronous step
            RecordingSentinel.delete(directory: tmp)
            appState.phase = .transcribing(progress: "Transcribing…")
        }

        try await h.coordinator.switchMicrophone(to: "mic-2")

        #expect(h.notified.value.isEmpty, "a clean Stop during the switch raised a false recovery warning")
    }

    @Test func switchWithTheRecoveryFileMissingSaysSo() async throws {
        // The sentinel was deleted mid-recording: the switch works, but a crash restart has nothing to
        // resume from on the new mic. That must not go unreported either.
        let h = try Harness()
        h.appState.phase = .recording(since: Date())
        h.recordingMic.set("mic-1")
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)   // precondition: no recovery file

        try await h.coordinator.switchMicrophone(to: "mic-2")

        #expect(h.recordingMic.current == .some("mic-2"))
        #expect(h.notified.value.map { $0.title } == ["Recovery File Not Updated"])
    }

    @Test func failedManualSwitchKeepsThePreviousMicMarked() async throws {
        let h = try Harness()
        _ = try h.writeSentinel(micDeviceUID: "mic-1")
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        h.client.updateMicError = FakeCaptureError()

        await #expect(throws: FakeCaptureError.self) {
            try await h.coordinator.switchMicrophone(to: "mic-2")
        }
        #expect(h.recordingMic.current == .some("mic-1"))
        #expect(RecordingSentinel.read(directory: h.tmp)?.micDeviceUID == "mic-1")
    }

    @Test func crashRestartMarksTheMicItResumedOn() async throws {
        let h = try Harness()
        _ = try h.writeSentinel(micDeviceUID: "mic-1")
        h.recordingMic.set("mic-2")   // stale: the restart below resumes on the sentinel's mic
        h.appState.phase = .recording(since: Date())
        let recordingMic = h.recordingMic
        var seenAtRestart: String??
        h.client.onStart = { seenAtRestart = recordingMic.current }

        await h.coordinator.handleXPCCrash()

        #expect(h.client.startCalls.last?.microphoneDeviceId == "mic-1")
        #expect(seenAtRestart == .some("mic-1"), "a meter could open the mic while the restart was opening it")
        #expect(h.recordingMic.current == .some("mic-1"), "meters could open the mic the restart resumed on")
    }

    @Test func aMicMarkedOutsideTheCoordinatorShowsInItsLabelState() async throws {
        // Flow A/B re-attach and its crash handler write RecordingMicrophone directly (no coordinator
        // exists yet at launch); the menu's mic label reads the coordinator — it must follow.
        let h = try Harness()
        h.recordingMic.set("mic-9")
        #expect(h.coordinator.helperMicKnown)
        #expect(h.coordinator.helperMicId == "mic-9")
        h.recordingMic.set(nil)   // helper auto-switched to the system default
        #expect(h.coordinator.helperMicKnown)
        #expect(h.coordinator.helperMicId == nil)
        h.recordingMic.clear()
        #expect(h.coordinator.helperMicKnown == false)
    }

    @Test func aCoordinatorCreatedAfterAReattachPicksUpTheMarkedMic() async throws {
        let recordingMic = RecordingMicrophone()
        recordingMic.set("reattached-mic")   // launch recovery ran before the menu built its coordinator
        let h = try Harness(recordingMic: recordingMic)
        #expect(h.coordinator.helperMicKnown)
        #expect(h.coordinator.helperMicId == "reattached-mic")
    }

    @Test func reattachedRecordingMirrorsHelperAutoSwitches() async throws {
        // Flow A: launch recovery re-attaches through the coordinator, which wires the helper's
        // mic-change report — meters and the menu label must follow an auto-switch (#192).
        let h = try Harness()
        _ = try h.writeSentinel(micDeviceUID: "mic-1")
        h.client.isCapturingResult = true
        await h.coordinator.recoverAtLaunch()
        #expect(h.recordingMic.current == .some("mic-1"))

        h.client.onMicDeviceChanged?("mic-7")
        var waited = 0
        while h.recordingMic.current != .some("mic-7"), waited < 200 {
            try await Task.sleep(nanoseconds: 5_000_000); waited += 1
        }
        #expect(h.recordingMic.current == .some("mic-7"))
        #expect(h.coordinator.helperMicId == "mic-7", "the menu's mic label did not follow the auto-switch")

        // A late report after the recording ended is ignored.
        h.appState.phase = .idle
        h.client.onMicDeviceChanged?("mic-8")
        for _ in 0..<50 { await Task.yield() }
        #expect(h.recordingMic.current == .some("mic-7"))
    }

    @Test func failedSwitchFromSystemDefaultRestoresSystemDefault() async throws {
        // The restore's `before` can be `.some(nil)` — recording on the system default. A failed switch
        // must put exactly that back (not "nothing marked", not the attempted mic).
        let h = try Harness()
        _ = try h.writeSentinel(micDeviceUID: nil)
        h.appState.phase = .recording(since: Date())
        h.recordingMic.set(nil)
        h.client.updateMicError = FakeCaptureError()

        await #expect(throws: FakeCaptureError.self) {
            try await h.coordinator.switchMicrophone(to: "mic-2")
        }
        #expect(h.recordingMic.current == .some(nil), "the system-default recording lost its marker")
        #expect(h.coordinator.helperMicKnown && h.coordinator.helperMicId == nil)
    }

    @Test func failedSwitchKeepsAMicTheHelperReportedMeanwhile() async throws {
        // The helper auto-switches to mic-3 while our switch to mic-2 is in flight, then our switch fails.
        // The restore must NOT overwrite the helper's own report with the pre-switch mic: it only puts
        // back `before` when the marker still holds exactly the mic we wrote.
        let h = try Harness()
        _ = try h.writeSentinel(micDeviceUID: "mic-1")
        h.appState.phase = .recording(since: Date())
        h.recordingMic.set("mic-1")
        let recordingMic = h.recordingMic
        h.client.onUpdateMicrophone = { await MainActor.run { recordingMic.set("mic-3") } }
        h.client.updateMicError = FakeCaptureError()

        await #expect(throws: FakeCaptureError.self) {
            try await h.coordinator.switchMicrophone(to: "mic-2")
        }
        #expect(h.recordingMic.current == .some("mic-3"), "the restore overwrote the helper's own report")
    }

    @Test func switchWhenTheRecordingAlreadyEndedTouchesNothing() async throws {
        let h = try Harness()   // idle: the recording ended while the switcher was open

        try await h.coordinator.switchMicrophone(to: "mic-2")

        #expect(h.client.micUpdates.isEmpty)
        #expect(h.recordingMic.current == .none, "an idle app marked a mic in use — its meter would stay off")
        #expect(h.coordinator.helperMicKnown == false)
    }

    @Test func failedSwitchAfterTheRecordingEndedDuringItLeavesNothingMarked() async throws {
        let h = try Harness()
        _ = try h.writeSentinel(micDeviceUID: "mic-1")
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        let coordinator = h.coordinator
        h.client.onUpdateMicrophone = { await coordinator.stopRecording() }   // the real Stop, mid-switch
        h.client.updateMicError = FakeCaptureError()   // "No capture in progress"

        await #expect(throws: FakeCaptureError.self) {
            try await h.coordinator.switchMicrophone(to: "mic-2")
        }
        #expect(h.client.stopCalls == 1)
        #expect(h.recordingMic.current == .none, "restoring the pre-switch mic resurrected it after the recording ended")
        #expect(h.coordinator.helperMicKnown == false)
        #expect(h.coordinator.helperMicId == nil)
    }

    @Test func failedSwitchInAReattachedRecordingKeepsItsMicMarked() async throws {
        // Flow A: the coordinator never started this recording, so helperMicKnown is false — but the
        // re-attach marked the sentinel's mic. A failed switch must restore THAT, not "system default".
        let h = try Harness()
        h.appState.phase = .recording(since: Date())
        h.recordingMic.set("sentinel-mic")
        h.client.updateMicError = FakeCaptureError()

        await #expect(throws: FakeCaptureError.self) {
            try await h.coordinator.switchMicrophone(to: "mic-2")
        }
        #expect(h.recordingMic.current == .some("sentinel-mic"))
    }

    @Test func failedSwitchNeverClearsTheMarkerMidRecording() async throws {
        // A recording whose mic was (wrongly) never marked — no path does this today; every way into a
        // live recording marks its mic first. A failed switch must not leave the app believing nothing
        // is recording: meters would then open the recording's mic. With no previous mic to restore,
        // the attempted one stays marked. Known, accepted limitation: the menu label then names that
        // mic until the recording ends or the user switches again. Keeping the meters safe wins.
        let h = try Harness()
        h.appState.phase = .recording(since: Date())
        h.client.updateMicError = FakeCaptureError()

        await #expect(throws: FakeCaptureError.self) {
            try await h.coordinator.switchMicrophone(to: "mic-2")
        }
        #expect(h.recordingMic.current == .some("mic-2"), "a live recording was left with no mic marked")
        #expect(h.coordinator.helperMicId == "mic-2")   // the accepted label limitation, pinned
    }

    @Test func switchDuringCrashRecoveryIsRefused() async throws {
        let h = try Harness()
        h.appState.phase = .recording(since: Date())
        h.coordinator.recoveryInFlight = true   // the restart will rewrite the sentinel from its own copy

        await #expect(throws: RecordingCoordinator.MicSwitchError.self) {
            try await h.coordinator.switchMicrophone(to: "mic-2")
        }
        #expect(h.client.micUpdates.isEmpty)
    }

    @Test func aSwitchWhileStopIsInFlightNeverReachesTheHelper() async throws {
        // The user taps Switch while Stop is waiting on the helper — the phase still reads "recording"
        // then. The helper must not be asked to switch mid-stop.
        let h = try Harness()
        h.appState.phase = .recording(since: Date())
        h.recordingMic.set("mic-1")
        let coordinator = h.coordinator
        var fireSwitch = true
        h.client.onStop = {
            if fireSwitch { fireSwitch = false; try? await coordinator.switchMicrophone(to: "mic-2") }
        }

        await h.coordinator.stopRecording()

        #expect(h.client.micUpdates.isEmpty, "a switch reached the helper while it was stopping")
    }

    @Test func aSecondStopWhileOneIsInFlightIsIgnored() async throws {
        // A second Stop lands while the first is suspended on the helper: it must not reach the helper
        // (or start a second transcription). One-shot, so a missing guard fails cleanly, not recursively.
        let h = try Harness()
        h.appState.phase = .recording(since: Date())
        let coordinator = h.coordinator
        var fireSecondStop = true
        h.client.onStop = {
            if fireSecondStop { fireSecondStop = false; await coordinator.stopRecording() }
        }

        await h.coordinator.stopRecording()

        #expect(h.client.stopCalls == 1, "a second Stop reached the helper while the first was in flight")
        #expect(h.coordinator.stopInFlight == false, "the in-flight flag leaked past the stop")
    }

    @Test func stopKeepsTheMicMarkedUntilTheHelperHasLetGo() async throws {
        let h = try Harness()
        h.recordingMic.set("mic-1")
        let recordingMic = h.recordingMic
        var seenDuringStop: String??
        h.client.onStop = { seenDuringStop = recordingMic.current }
        // stopResult nil → stop() throws: the failure path must release the mic too.

        await h.coordinator.stopRecording()

        #expect(seenDuringStop == .some("mic-1"), "the mic was released while the helper still held it")
        #expect(h.recordingMic.current == .none)
    }

    // #155: the stop-path catch is the user's only signal on this path — the sentinel is deleted
    // unconditionally, so relaunching will not retry. It must tell the user their raw audio is
    // still on disk (§7.4 P6: what the salvage did, from the outcome).
    @Test func stopFailureNotifiesCriticallyThatAudioWasPreserved() async throws {
        let h = try Harness()
        // A re-attached recording (no live pipeline) whose session already has a chunk on disk.
        let sentinel = try h.writeSentinel(sessionId: "sess")
        let outDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        try SessionState.write(SessionState(
            sessionId: "sess", meetingStart: Date(), engine: h.config.config.engine.rawValue, chunkDurationMinutes: 10,
            chunks: [ProcessedChunk(index: 0, startTime: Date(), audioPath: outDir.appendingPathComponent("sess-0.m4a").path,
                                    segments: [], speakerDatabase: [:])]
        ), directory: outDir)
        // stopResult nil → stop() throws, landing in the outer catch.

        await h.coordinator.stopRecording()

        let critical = try #require(h.criticals.value.first)
        #expect(critical.title == "Transcription Failed")
        // §7.4 P6: says what is on disk, never a transcript that does not exist.
        #expect(critical.body.hasPrefix("Stopping the recording failed"))
        #expect(critical.body.contains("1 chunk recorded before it is kept on disk"))
        #expect(h.notified.value.isEmpty, "should escalate via the critical path, not the routine notify")
    }

    /// L6 fix round 1, item 1 (CRITICAL): the stop SUCCEEDED (the sentinel is already deleted) and
    /// transcription then threw. The catch must use the sentinel read before the stop: the chunk is
    /// kept on disk — never "no recorded audio" — and it must not say the stop failed.
    @Test func transcriptionFailureAfterASuccessfulStopSaysTheAudioIsKept() async throws {
        let h = try Harness()
        h.config.update { $0.engine = .fluidAudio }   // constructor only; models are never loaded here
        let sentinel = try h.writeSentinel(sessionId: "sess")
        let outDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        try SessionState.write(SessionState(
            sessionId: "sess", meetingStart: Date(), engine: h.config.config.engine.rawValue, chunkDurationMinutes: 10,
            chunks: [ProcessedChunk(index: 0, startTime: Date(), audioPath: outDir.appendingPathComponent("sess-0.m4a").path,
                                    segments: [], speakerDatabase: [:])]
        ), directory: outDir)
        h.client.stopResult = AudioPaths(systemAudio: outDir.appendingPathComponent("sess-9.wav"),
                                         micAudio: outDir.appendingPathComponent("sess-9_mic.wav"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: outDir.path)   // the transcript can't be written
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outDir.path) }

        await h.coordinator.stopRecording()

        let critical = try #require(h.criticals.value.first)
        #expect(critical.body.contains("kept on disk") && !critical.body.contains("no recorded audio"), "\(critical.body)")
        #expect(critical.body.hasPrefix("The recording stopped"), "the stop itself succeeded")
        #expect(critical.title == "Transcription Failed")
    }

    /// L6 fix round 1, item 2: a stop failure inside the FIRST chunk — the in-progress chunk is the
    /// whole recording, so it is re-ingested (as the give-up path does), never reported as "no audio".
    @Test func aStopFailureWithinTheFirstChunkSalvagesTheInProgressChunk() async throws {
        let h = try Harness()
        h.config.update {
            $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path
            $0.engine = .fluidAudio
        }
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        defer {
            h.runner.stopChunkRotation()
            h.runner.teardownChunkedPipeline()
        }
        let rotator = try #require(h.runner.chunkRotator)
        let sentinel = try #require(RecordingSentinel.read(directory: h.tmp))
        let outDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try Harness.headerOnlyWAV().write(to: outDir.appendingPathComponent(rotator.currentBaseName + ".wav"))
        h.client.stopError = FakeCaptureError()

        await h.coordinator.stopRecording()

        let critical = try #require(h.criticals.value.first)
        #expect(!critical.body.contains("no recorded audio"), "\(critical.body)")
        #expect(critical.body.hasPrefix("Stopping the recording failed"))
    }

    /// A 44-byte PCM WAV with no samples: a real chunk file that needs no model to process.

    @Test func stopFailureWithNothingOnDiskSaysSo() async throws {
        let h = try Harness()
        await h.coordinator.stopRecording()   // no sentinel, no session: nothing recorded
        let critical = try #require(h.criticals.value.first)
        #expect(critical.body == RecoveryMessages.stopFailed(
            after: SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0), error: CocoaError(.fileNoSuchFile).localizedDescription))
    }

    @Test func crashWithoutSentinelEscalatesCritically() async throws {
        let h = try Harness()

        await h.coordinator.handleXPCCrash()

        #expect(h.appState.criticalError?.hasPrefix("Recording failed — no recovery data available.") == true)
        #expect(h.appState.isIdle)
        #expect(h.criticals.value.map { $0.title } == ["Recording Failed"])
        #expect(h.client.startCalls.isEmpty)
        #expect(h.client.captureEndedCalls == 1)
        #expect(h.client.retryEvents == [["attempt": "1", "giveUp": "false"]])
    }

    @Test func crashWithNoLivePipelineRestartsInChunkIndexNamespace() async throws {
        let h = try Harness()
        let sentinel = try h.writeSentinel(sessionId: "sess", segment: 1, chunkIndex: 0)
        h.appState.phase = .recording(since: Date())

        await h.coordinator.handleXPCCrash()

        // #135: the restart is named in the chunk-index namespace with the collision-guarded
        // index (no session.json, no WAVs on disk -> floor at sentinel.chunkIndex + 1 = 1),
        // never the legacy segment counter.
        #expect(h.client.startCalls.count == 1)
        #expect(h.client.startCalls[0].baseName == "sess-1")
        #expect(h.client.startCalls[0].microphoneDeviceId == sentinel.micDeviceUID)
        // F4: the base name moved on (sess-0 -> sess-1) but the session id is the one the original
        // capture belonged to — L11 resets the diagnostics ring only when it changes.
        #expect(h.client.startCalls[0].sessionId == "sess", "an in-session restart must keep the session id")

        let rewritten = try #require(RecordingSentinel.read(directory: h.tmp))
        #expect(rewritten.segment == sentinel.segment + 1)
        #expect(rewritten.chunkIndex == 1)  // stamped directly (#154 finding 6)
        #expect(rewritten.systemAudioPath.hasSuffix("sess-1.wav"))
        #expect(rewritten.micAudioPath.hasSuffix("sess-1_mic.wav"))

        // L9: `start()` returning proves nothing (the helper replies before its first frame, and a
        // first-sample crash comes back as another interruption). The streak resets only after
        // confirmed frames — see retryStreakResetsOnlyAfterConfirmedFrames.
        #expect(h.coordinator.xpcRetryCount == 1)
        #expect(h.client.captureEndedCalls == 0, "a restart does not end the recording")
        // Honest "Resumed" (L2): nothing is announced until frames arrive.
        #expect(h.notified.value.isEmpty)
        #expect(h.appState.interruptionWarning == "Recording restarted — waiting for audio…")
        #expect(h.coordinator.recoveryInFlight == false)
    }

    // NOTE: tests ESCALATION only (no live pipeline here, so the salvage attempt is a no-op).
    // The salvage path itself is covered by RecordingCoordinatorSalvageTests.
    @Test func crashRestartFailureEscalatesCritically() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.client.startError = FakeCaptureError()

        await h.coordinator.handleXPCCrash()

        // L6 fix round 1, item 5: the banner says what the salvage did, never "has been saved" blindly.
        #expect(h.appState.criticalError == "Recording failed — could not restart capture: fake capture failure. "
                + RecoveryMessages.outcomeSentence(SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0)))
        #expect(h.appState.isIdle)
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
        #expect(h.criticals.value.map { $0.title } == ["Recording Failed"])
        #expect(h.criticals.value.first?.body == RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0)),
                "never 'has been transcribed' when nothing was (§7.4 P6)")
        #expect(h.client.captureEndedCalls == 1)
    }

    // NOTE: tests the give-up ESCALATION only (no live pipeline, so nothing to salvage here).
    // The salvage path itself is covered by RecordingCoordinatorSalvageTests.
    @Test func crashLoopWithinDecayWindowGivesUp() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        // Seed an exhausted streak: the next crash inside the decay window exceeds maxRetries.
        h.coordinator.xpcRetryCount = XPCRetryPolicy.defaultMaxRetries
        h.coordinator.lastCrashAt = Date()

        await h.coordinator.handleXPCCrash()

        #expect(h.client.startCalls.isEmpty)  // no restart attempt after give-up
        #expect(h.appState.criticalError == "Recording failed — capture crashed repeatedly. "
                + RecoveryMessages.outcomeSentence(SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0)))
        #expect(h.appState.isIdle)
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
        #expect(h.criticals.value.map { $0.title } == ["Recording Failed"])
        #expect(h.client.retryEvents == [["attempt": "3", "giveUp": "true"]])
        #expect(h.criticals.value.first?.body == RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0)))
        #expect(h.client.captureEndedCalls == 1)
    }

    @Test func crashAfterDecayIntervalStartsAFreshStreak() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())   // the crash handler runs only for a live recording
        // #61: the streak decays — an old exhausted streak must NOT trip the cap.
        h.coordinator.xpcRetryCount = XPCRetryPolicy.defaultMaxRetries
        h.coordinator.lastCrashAt = Date().addingTimeInterval(-(XPCRetryPolicy.defaultDecayInterval + 1))

        await h.coordinator.handleXPCCrash()

        #expect(h.client.startCalls.count == 1)  // restarted instead of giving up
        #expect(h.appState.criticalError == nil)
        #expect(h.notified.value.isEmpty && h.appState.interruptionWarning == "Recording restarted — waiting for audio…")
    }

    @Test func stopDuringRecoveryDefersToTheRecoveryHandler() async throws {
        let h = try Harness()
        // council FV2: a Stop mid-recovery must not race the helper restart.
        h.coordinator.recoveryInFlight = true

        await h.coordinator.stopRecording()

        #expect(h.coordinator.stopRequestedDuringRecovery == true)
        #expect(h.appState.phase == .transcribing(progress: "Finishing…"))
        #expect(h.client.stopCalls == 0)
    }

    // council FV2, the completion half of the deferral above: once the restart succeeds, a stop
    // requested during recovery is honored — the recovery handler runs a real stop instead of
    // resuming. (`stop()` is made to throw so the honored stop takes the defense-in-depth catch
    // rather than driving a real transcription engine; `stopCalls == 1` is the honor proof.)
    @Test func stopRequestedDuringRecoveryIsHonoredAfterRestart() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.client.stopError = FakeCaptureError()
        h.coordinator.stopRequestedDuringRecovery = true

        await h.coordinator.handleXPCCrash()

        #expect(h.client.startCalls.count == 1)  // capture restarted first…
        #expect(h.client.stopCalls == 1)  // …then the deferred stop actually ran
        #expect(!h.notified.value.contains { $0.title == "Recording Resumed" })  // not the resume path
        #expect(h.coordinator.stopRequestedDuringRecovery == false)
        #expect(h.coordinator.recoveryInFlight == false)
    }

    // #135: with no live pipeline and a recoverable session.json in the SENTINEL's output dir,
    // stop must select the chunked-recovery branch keyed by the sentinel-derived sessionId — not
    // the legacy path derived from whichever WAV the stop returned.
    @Test func fallbackStopSelectsChunkedRecoveryFromSentinelSession() async throws {
        let h = try Harness()
        // Pin the engine whose constructor is cheap and OS-independent — prepareEngine only
        // constructs the engine object here; models load lazily and are never touched.
        h.config.update { $0.engine = .fluidAudio }
        let sentinel = try h.writeSentinel(sessionId: "sess")
        let outDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        try SessionState.write(SessionState(
            sessionId: "sess", meetingStart: Date(), engine: h.config.config.engine.rawValue,
            chunkDurationMinutes: 10,
            chunks: [ProcessedChunk(
                index: 0, startTime: Date(),
                audioPath: outDir.appendingPathComponent("sess-0.m4a").path,
                segments: [], speakerDatabase: [:]
            )]
        ), directory: outDir)
        // The stopped WAV points at a DIFFERENT location/session on purpose.
        let stoppedDir = h.tmp.appendingPathComponent("stopped")
        try FileManager.default.createDirectory(at: stoppedDir, withIntermediateDirectories: true)
        h.client.stopResult = AudioPaths(
            systemAudio: stoppedDir.appendingPathComponent("live-9.wav"),
            micAudio: stoppedDir.appendingPathComponent("live-9_mic.wav")
        )

        await h.coordinator.stopRecording()

        // The recover branch ran: provenance was finalized for the sentinel-derived session in the
        // sentinel's output dir, never for the stopped path's "live" session.
        let first = try #require(h.client.finalizeCalls.first)
        #expect(first.sessionId == "sess")
        #expect(first.recordingDirectory == outDir)
        #expect(!h.client.finalizeCalls.contains { $0.sessionId == "live" })
    }

    @Test func startRecordingSuccessPersistsSentinelAndEntersRecording() async throws {
        let h = try Harness()
        // Keep the session's output directory inside the test sandbox, and pin the engine whose
        // constructor is cheap and OS-independent (models load lazily, never touched here).
        h.config.update {
            $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path
            $0.engine = .fluidAudio
        }
        h.coordinator.xpcRetryCount = 1  // proves the counters reset on a fresh start
        h.coordinator.lastCrashAt = Date()

        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        defer {
            h.runner.stopChunkRotation()
            h.runner.teardownChunkedPipeline()
        }

        #expect(h.appState.isRecording)
        #expect(h.appState.errorMessage == nil)
        let sentinel = try #require(RecordingSentinel.read(directory: h.tmp))  // persists on success
        #expect(sentinel.segment == 1)
        #expect(sentinel.chunkIndex == 0)
        #expect(sentinel.systemAudioPath.hasSuffix("-Test-0.wav"))
        #expect(h.coordinator.helperMicKnown == true)
        #expect(h.coordinator.helperMicId == "mic-1")
        #expect(h.coordinator.xpcRetryCount == 0)
        #expect(h.coordinator.lastCrashAt == nil)
        #expect(h.coordinator.recoveryInFlight == false)
        #expect(h.coordinator.stopRequestedDuringRecovery == false)
        #expect(h.runner.chunkRotator != nil)  // chunked pipeline is live
        #expect(h.runner.chunkProcessor != nil)
        #expect(h.notified.value.isEmpty)
    }

    @Test func crashCallbacksAreNoOpsWhenNotRecording() async throws {
        let h = try Harness()
        // Wire the callbacks via a failed start (cheapest wiring path), then arm a clean restart.
        h.client.startError = FakeCaptureError()
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: nil)
        h.client.startError = nil
        _ = try h.writeSentinel()
        let wiredStarts = h.client.startCalls.count  // 1 (the failed start)

        // Positive control: while recording, the wired callback drives a real recovery restart.
        h.appState.phase = .recording(since: Date())
        h.client.onServiceCrash?()
        var tries = 0
        while h.client.startCalls.count < wiredStarts + 1 && tries < 1000 {
            await Task.yield()
            tries += 1
        }
        #expect(h.client.startCalls.count == wiredStarts + 1)

        // guard appState.isRecording: when idle, the same callbacks must do nothing.
        h.appState.phase = .idle
        h.appState.criticalError = nil
        h.client.onServiceCrash?()
        h.client.onFatalFailure?("boom")
        for _ in 0..<50 { await Task.yield() }
        #expect(h.client.startCalls.count == wiredStarts + 1)  // no further restart attempt
        #expect(h.appState.criticalError == nil)
    }

    /// v2 F4: the coordinator hands the helper the capture options built from config, before start.
    @Test func startPassesTheConfiguredCaptureOptionsToTheHelper() async throws {
        let h = try Harness()
        h.config.update { $0.tapAutoStart = false; $0.debugDropTapFrames = true }
        await h.coordinator.startRecording(sessionName: "Test", microphoneDeviceId: "mic-1")
        let call = try #require(h.client.startCalls.first)
        #expect(call.options == CaptureOptions(tapAutoStart: false, remoteExactZeroSoftAlarmSeconds: nil, debugDropTapFrames: true))
        #expect(call.sessionId.hasSuffix("-Test"), "the session id is the chunk base name (HHmmss-name)")
        #expect(call.baseName == call.sessionId + "-0", "the session id is the chunk base name without the chunk index")
    }
}

// MARK: - Abandoned-session salvage (council F3)

@MainActor
@Suite struct RecordingCoordinatorSalvageTests {
    @Test func salvageEmptySessionTearsDownWithoutTranscript() async throws {
        let h = try Harness()
        let state = SessionState(
            sessionId: "sess", meetingStart: Date(),
            engine: h.config.config.engine.rawValue, chunkDurationMinutes: 10, chunks: []
        )

        let outcome = await h.coordinator.salvageAbandonedSession(
            sessionState: state, outputDir: h.tmp.appendingPathComponent("out")
        )

        #expect(outcome == SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0))
        // Nothing to salvage: no provenance finalization, no transcript published.
        #expect(h.client.finalizeCalls.isEmpty)
        #expect(h.appState.lastJsonPath == nil)
        #expect(h.appState.lastTranscriptPath == nil)
    }

    @Test func salvageNonEmptySessionStampsProvenanceBeforeFinalizing() async throws {
        let h = try Harness()
        let outDir = h.tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let state = SessionState(
            sessionId: "sess", meetingStart: Date(),
            engine: h.config.config.engine.rawValue, chunkDurationMinutes: 10,
            chunks: [ProcessedChunk(
                index: 0, startTime: Date(),
                audioPath: outDir.appendingPathComponent("sess-0.m4a").path,
                segments: [.init(
                    start: 0, end: 1, text: "hello", speaker: "Speaker 1",
                    source: "remote", qualityScore: nil
                )],
                speakerDatabase: [:]
            )]
        )

        let outcome = await h.coordinator.salvageAbandonedSession(sessionState: state, outputDir: outDir)

        // The salvage path drains diagnostics and stamps provenance for THIS session before
        // finalizing (the whole point of council F3 + #95).
        let first = try #require(h.client.finalizeCalls.first)
        #expect(first.sessionId == "sess")
        #expect(first.recordingDirectory == outDir)
        // One chunk → no concatenation; finalize assembles the JSON from the chunk's segments and writes it
        // (TranscriptionRunner.finalize:335-460 reads no audio for a single chunk), so this fixture's
        // non-existent .m4a is fine: the transcript IS written.
        #expect(outcome.chunkCount == 1)
        #expect(outcome.kind == .transcriptWritten(outDir.appendingPathComponent("sess.json")))
        #expect(h.appState.lastJsonPath == outDir.appendingPathComponent("sess.json").path)
    }

    @Test func aFinalizeFailureIsReportedNotSwallowed() async throws {
        let h = try Harness()
        let outDir = h.tmp.appendingPathComponent("nowrite")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: outDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outDir.path) }
        let state = SessionState(sessionId: "sess", meetingStart: Date(), engine: h.config.config.engine.rawValue, chunkDurationMinutes: 10,
                                 chunks: [ProcessedChunk(index: 0, startTime: Date(), audioPath: "sess-0.m4a", segments: [], speakerDatabase: [:])])
        let outcome = await h.coordinator.salvageAbandonedSession(sessionState: state, outputDir: outDir)
        guard case .finalizeFailed = outcome.kind else { Issue.record("expected finalizeFailed, got \(outcome.kind)"); return }
        #expect(outcome.chunkCount == 1)
        #expect(h.appState.lastJsonPath == nil)
    }

    /// §7.4 P6: a relaunch that cannot resume transcribes what reached disk, presents it like a normal
    /// stop, and says loudly — the sticky alarm, presented at once — that the recording STOPPED.
    @Test func launchSalvageIsPresentedAndSaysTheRecordingStopped() async throws {
        let h = try Harness()
        let shown = Harness.Box<[(due: [AlarmKind], new: [AlarmKind])]>([])
        let coordinator = RecordingCoordinator(
            appState: h.appState, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { _, _ in }, notifyCritical: { h.criticals.value.append(($0, $1)) },
            presentTranscript: { url, _ in h.presented.value.append(url) },
            presentAlarmsUI: { due, new in shown.value.append((due.map(\.kind), new)) },
            engineFactory: { _ in (FakeEngine(), FakeDiarizer()) }, recordingMicrophone: h.recordingMic)
        let sentinel = try h.writeSentinel(sessionId: "sess")
        let outDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        try SessionState.write(SessionState(
            sessionId: "sess", meetingStart: Date(), engine: h.config.config.engine.rawValue, chunkDurationMinutes: 10,
            chunks: [ProcessedChunk(index: 0, startTime: Date(), audioPath: outDir.appendingPathComponent("sess-0.m4a").path,
                                    segments: [.init(start: 0, end: 1, text: "hello", speaker: "Speaker 1", source: "remote", qualityScore: nil)],
                                    speakerDatabase: [:])]
        ), directory: outDir)

        await coordinator.recoverAtLaunch()   // helper not capturing → Flow B, chunked

        let json = outDir.appendingPathComponent("sess.json")
        #expect(h.presented.value == [json], "the recovered transcript goes through the normal completion path")
        #expect(h.appState.activeAlarms[.recordingStopped]?.message == RecoveryMessages.relaunchStopped(
            at: sentinel.startedAt, outcome: SalvageOutcome(kind: .transcriptWritten(json), chunkCount: 1)))
        // L6 fix round 1, item 3: presented NOW (window + one notification), not at the next recording.
        #expect(shown.value.count == 1 && shown.value.first?.new == [.recordingStopped])
        #expect(h.criticals.value.isEmpty, "exactly one notification: the presenter's")
        #expect(coordinator.presentedKinds.contains(.recordingStopped))
        #expect(h.appState.isIdle && RecordingSentinel.read(directory: h.tmp) == nil)
        #expect(h.client.captureEndedCalls == 1)

        // The next recording's first presentation does not re-open or re-post it.
        h.appState.phase = .recording(since: Date())
        coordinator.presentAlarms()
        #expect(shown.value.count == 1)
    }

    /// Item 8: the failure branch — the engine cannot even be prepared; the chunk stays on disk.
    @Test func launchSalvageFailureSaysTheChunksAreKeptOnDisk() async throws {
        let h = try Harness()
        let coordinator = RecordingCoordinator(
            appState: h.appState, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { _, _ in }, notifyCritical: { _, _ in }, presentTranscript: { _, _ in },
            engineFactory: { _ in throw FakeCaptureError() }, recordingMicrophone: h.recordingMic)
        let sentinel = try h.writeSentinel(sessionId: "sess")
        let outDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        try SessionState.write(SessionState(
            sessionId: "sess", meetingStart: Date(), engine: h.config.config.engine.rawValue, chunkDurationMinutes: 10,
            chunks: [ProcessedChunk(index: 0, startTime: Date(), audioPath: outDir.appendingPathComponent("sess-0.m4a").path,
                                    segments: [], speakerDatabase: [:])]
        ), directory: outDir)
        await coordinator.salvageAtLaunch(sentinel: sentinel, outputDir: outDir)
        #expect(h.appState.activeAlarms[.recordingStopped]?.message == RecoveryMessages.relaunchStopped(
            at: sentinel.startedAt, outcome: SalvageOutcome(kind: .finalizeFailed(FakeCaptureError().localizedDescription), chunkCount: 1)))
        #expect(h.appState.isIdle && RecordingSentinel.read(directory: h.tmp) == nil)
    }

    /// Item 8: the nil branch — nothing on disk to recover.
    @Test func launchSalvageWithNothingOnDiskSaysSo() async throws {
        let h = try Harness()
        let sentinel = try h.writeSentinel(sessionId: "sess")
        let outDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        await h.coordinator.salvageAtLaunch(sentinel: sentinel, outputDir: outDir)
        #expect(h.appState.activeAlarms[.recordingStopped]?.message == RecoveryMessages.relaunchStopped(
            at: sentinel.startedAt, outcome: SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0)))
    }
}

// MARK: - Honest relaunch (L7, §8.3, §8.9)

@MainActor
@Suite struct RecordingCoordinatorRelaunchTests {
    private func writeSentinel(_ h: Harness, alive: TimeInterval?, boot: String? = BootSession.currentUUID(), stopping: Bool = false) throws -> RecordingSentinel {
        var s = try h.writeSentinel()
        s.lastAliveAt = alive.map { Date().addingTimeInterval(-$0) }
        s.bootSessionUUID = boot
        s.stopping = stopping
        try RecordingSentinel.write(s, directory: h.tmp)
        return s
    }

    private func outDir(_ s: RecordingSentinel) -> URL { URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent() }

    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
    }

    /// L1 (§8.3): the app died 30 s ago; the helper is gone; resume the SAME session and say so.
    @Test func freshSentinelResumesTheSameSessionAndRecordsTheGap() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try writeSentinel(h, alive: 30)
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.count == 1 && h.client.startCalls[0].baseName == "sess-1")
        #expect(h.client.startCalls.first?.sessionId == "sess", "the same session id (the R5 gate refuses any other)")
        #expect(h.appState.isRecording)
        #expect(h.appState.activeAlarms[.recordingResumedWithGap]?.message.contains("resumed at") == true)
        #expect(h.client.launchRecoveries.first?["flow"] == "resume")
        #expect(h.client.recordedEvents.contains { $0.kind == .captureGap && $0.detail["reason"] == "app relaunch" })
        let written = try #require(RecordingSentinel.read(directory: h.tmp))
        #expect((written.lastAliveAt ?? .distantPast) > Date().addingTimeInterval(-5), "refreshed at the resume")
        #expect(written.chunkIndex == 1 && !written.stopping && written.bootSessionUUID == BootSession.currentUUID())
        let state = try #require(await h.runner.chunkProcessor?.getSessionState())
        #expect(state.chunks.map(\.index) == [0], "seeded from session.json")
        #expect(state.gaps.map(\.reason) == ["app relaunch"])
        #expect(h.criticals.value.isEmpty, "one notification: the alarm presenter's")
    }

    /// 41(a)(b): the resume's alarm reaches the presenter (window + notification), and the resumed chunk
    /// clock is re-anchored at resume time, never at the seeded meeting start.
    @Test func theResumeAlarmIsPresentedAndTheClockReanchored() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let shown = Harness.Box<[AlarmKind]>([])
        let coordinator = RecordingCoordinator(
            appState: h.appState, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { _, _ in }, notifyCritical: { _, _ in }, presentTranscript: { _, _ in },
            presentAlarmsUI: { _, new in shown.value += new },
            engineFactory: { _ in (FakeEngine(), FakeDiarizer()) }, recordingMicrophone: h.recordingMic)
        let s = try writeSentinel(h, alive: 30)
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt.addingTimeInterval(-3600), chunkIndices: [0])
        await coordinator.recoverAtLaunch()
        #expect(shown.value.contains(.recordingResumedWithGap))
        let start = try #require(h.runner.chunkRotator?.currentChunkInfo.startTime)
        #expect(abs(start.timeIntervalSinceNow) < 5, "re-anchored now, not an hour ago")
    }

    @Test func oldSentinelSalvagesAndStopsLoudly() async throws {
        let h = try Harness()
        _ = try writeSentinel(h, alive: 600)
        let lastAlive = try #require(RecordingSentinel.read(directory: h.tmp)?.lastAliveAt)
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.isEmpty && h.appState.isIdle)
        let stopped = try #require(h.appState.activeAlarms[.recordingStopped])
        #expect(stopped.message.hasPrefix("Recording STOPPED at \(RecoveryMessages.clock(lastAlive))"), "the last-alive time, never the start")
        #expect(RecordingSentinel.read(directory: h.tmp) == nil, "deleted only after the salvage ran")
    }

    /// Scan A163/C16: a crash during post-Stop finalize must not restart a recording the user stopped.
    @Test func aStoppingSentinelIsSalvagedNeverResumed() async throws {
        let h = try Harness()
        _ = try writeSentinel(h, alive: 5, stopping: true)
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.isEmpty && h.appState.isIdle)
        #expect(h.appState.activeAlarms[.recordingStopped] != nil)
    }

    /// C7 round 1: a stop-in-flight race — the helper still captures. Never re-attached: it is stopped
    /// (bounded) BEFORE the salvage, so the salvage sees its sealed chunk.
    @Test func aStoppingSentinelWithACapturingHelperStopsItBeforeTheSalvage() async throws {
        let h = try Harness()
        _ = try writeSentinel(h, alive: 5, stopping: true)
        h.client.isCapturingResult = true
        h.client.stopResult = AudioPaths(systemAudio: h.tmp.appendingPathComponent("x.wav"), micAudio: h.tmp.appendingPathComponent("x_mic.wav"))
        let phaseAtStop = Harness.Box<AppState.Phase?>(nil)
        let state = h.appState
        h.client.onStop = { phaseAtStop.value = state.phase }
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.stopCalls == 1)
        #expect(phaseAtStop.value == .idle, "stopped before the salvage began")
        #expect(!h.client.launchRecoveries.contains { $0["flow"] == "A" } && h.appState.isIdle)
        #expect(h.appState.activeAlarms[.recordingStopped] != nil)
    }

    @Test func aSentinelFromAnotherBootIsSalvagedNotDeleted() async throws {
        let h = try Harness()
        let s = try writeSentinel(h, alive: 10, boot: "not-this-boot")
        // Audio on disk (41d): salvaged into a transcript, never discarded with the stale sentinel.
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.isEmpty && h.appState.activeAlarms[.recordingStopped] != nil)
        #expect(h.presented.value == [outDir(s).appendingPathComponent("sess.json")], "salvaged, not deleted")
    }

    /// L9 review 44: the resume's start timed out — it may still commit — so the helper is stopped, bounded,
    /// before the session is salvaged.
    @Test func aResumeWhoseStartTimesOutStopsTheHelper() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try writeSentinel(h, alive: 30)
        h.client.startError = CaptureCallTimeout(call: "start", seconds: 15)
        h.client.stopResult = AudioPaths(systemAudio: h.tmp.appendingPathComponent("x.wav"), micAudio: h.tmp.appendingPathComponent("x_mic.wav"))
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.count == 1 && h.client.stopCalls == 1)
        #expect(h.appState.isIdle && h.appState.activeAlarms[.recordingStopped] != nil)
    }

    /// L9 review 49: a relaunch ping the helper does not answer is "unknown", never "not capturing": the helper
    /// is stopped (bounded) before any salvage.
    @Test func anUnansweredPingAtRelaunchStopsTheHelperBeforeTheSalvage() async throws {
        let h = try Harness()
        _ = try writeSentinel(h, alive: 600)
        h.client.captureStateResult = .unknown
        h.client.stopResult = AudioPaths(systemAudio: h.tmp.appendingPathComponent("x.wav"), micAudio: h.tmp.appendingPathComponent("x_mic.wav"))
        let phaseAtStop = Harness.Box<AppState.Phase?>(nil)
        let state = h.appState
        h.client.onStop = { phaseAtStop.value = state.phase }
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.stopCalls == 1 && phaseAtStop.value == .idle, "stopped before the salvage began")
        #expect(h.appState.activeAlarms[.recordingStopped] != nil)
    }

    /// L9 review 49: … and a helper that answers neither the ping nor the stop keeps its session: never
    /// salvaged while it may still be writing.
    @Test func anUnansweredHelperThatWillNotStopKeepsItsSession() async throws {
        let h = try Harness()
        let s = try writeSentinel(h, alive: 600)
        h.client.captureStateResult = .unknown
        h.coordinator.helperStopDeadline = .milliseconds(100)
        h.client.onStop = { try? await Task.sleep(for: .seconds(2)) }
        await h.coordinator.recoverAtLaunch()
        #expect(RecordingSentinel.readPending(directory: h.tmp).map(\.sessionKey) == [s.sessionKey])
        #expect(h.presented.value.isEmpty && h.client.droppedConnections == 1)
    }

    @Test func stopMarksTheSentinelStoppingBeforeAskingTheHelper() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let seen = Harness.Box<Bool?>(nil)
        h.client.onStop = { seen.value = RecordingSentinel.read(directory: h.tmp)?.stopping }
        h.client.stopError = FakeCaptureError()
        await h.coordinator.stopRecording()
        #expect(seen.value == true)
    }

    /// A Stop deferred while a crash restart is in flight is still the user's Stop: a crash before the
    /// deferred stop runs must salvage at relaunch, never resume.
    @Test func aStopDeferredDuringRecoveryMarksTheSentinelStopping() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        h.client.stopError = FakeCaptureError()
        let coordinator = h.coordinator
        let markedWhileRestarting = Harness.Box<Bool?>(nil)
        h.client.onStartAsync = {
            await coordinator.stopRecording()   // deferred: recovery is in flight
            markedWhileRestarting.value = RecordingSentinel.read(directory: h.tmp)?.stopping
        }
        await h.coordinator.handleXPCCrash()
        #expect(markedWhileRestarting.value == true)
    }

    @Test func refreshSentinelLivenessRewritesLastAliveAt() throws {
        let h = try Harness()
        _ = try writeSentinel(h, alive: 30)
        let now = Date(timeIntervalSince1970: 5_000)
        h.coordinator.refreshSentinelLiveness(now: now)
        #expect(RecordingSentinel.read(directory: h.tmp)?.lastAliveAt == now)
    }

    @Test func refreshNeverCreatesASentinel() throws {
        let h = try Harness()
        h.coordinator.refreshSentinelLiveness()
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
    }

    /// A recording writes its boot session and liveness at start, and the alive timer keeps it fresh.
    @Test func theAliveTimerKeepsTheSentinelFresh() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        h.coordinator.aliveRefreshInterval = .milliseconds(20)
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        var written = try #require(RecordingSentinel.read(directory: h.tmp))
        #expect(written.bootSessionUUID == BootSession.currentUUID() && written.lastAliveAt != nil && !written.stopping)
        let stale = Date(timeIntervalSince1970: 1_000)
        written.lastAliveAt = stale
        try RecordingSentinel.write(written, directory: h.tmp)
        var waited = 0
        while RecordingSentinel.read(directory: h.tmp)?.lastAliveAt == stale, waited < 200 {
            try await Task.sleep(nanoseconds: 5_000_000); waited += 1
        }
        #expect((RecordingSentinel.read(directory: h.tmp)?.lastAliveAt ?? stale) > stale)
    }

    /// §8.3: `lastAliveAt` is refreshed "every 60 s and at every rotation".
    @Test func aRotationRefreshesTheSentinel() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        var written = try #require(RecordingSentinel.read(directory: h.tmp))
        let stale = Date(timeIntervalSince1970: 1_000)
        written.lastAliveAt = stale
        try RecordingSentinel.write(written, directory: h.tmp)
        await h.runner.chunkRotator?.rotateForTesting()
        #expect((RecordingSentinel.read(directory: h.tmp)?.lastAliveAt ?? stale) > stale)
    }

    /// Flow A (the helper still captures): re-attached, and the sentinel is refreshed at once — a second
    /// crash within the first minute must still resume.
    @Test func aReattachRefreshesTheSentinelAtOnce() async throws {
        let h = try Harness()
        _ = try writeSentinel(h, alive: 150)
        h.client.isCapturingResult = true
        await h.coordinator.recoverAtLaunch()
        #expect(h.appState.isRecording && h.client.startCalls.isEmpty)
        #expect((RecordingSentinel.read(directory: h.tmp)?.lastAliveAt ?? .distantPast) > Date().addingTimeInterval(-5))
    }

    /// IMPORTANT (ledger, L7): the orphan scan runs BEFORE the helper starts. After the start the helper's
    /// live file exists; ingested as an orphan it would be processed mid-recording, and its real
    /// finalization skipped as a duplicate — everything after the snapshot lost. The fake creates it.
    @Test func aResumeNeverIngestsTheLiveFileAsAnOrphan() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try writeSentinel(h, alive: 20)
        let dir = outDir(s)
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        try Harness.headerOnlyWAV().write(to: dir.appendingPathComponent("sess-1.wav"))   // the chunk the crash cut short
        let client = h.client
        client.onStart = {   // the helper creates its live file at start, as the real one does
            guard let call = client.startCalls.last else { return }
            try? Harness.headerOnlyWAV().write(to: call.outputDirectory.appendingPathComponent(call.baseName + ".wav"))
        }
        await h.coordinator.recoverAtLaunch()
        #expect(client.startCalls.first?.baseName == "sess-2", "a free index, chosen before the start")
        #expect(h.runner.chunkRotator?.currentBaseName == "sess-2", "the rotator names the file the helper writes")
        let processor = try #require(h.runner.chunkProcessor)
        await processor.awaitAllProcessed()
        let indices = await processor.getSessionState().chunks.map(\.index).sorted()
        #expect(indices == [0, 1], "the orphan went through the LIVE processor; the live file did not")
    }

    /// The free index skips every artefact a chunk leaves, the archive included: a chunk archived just
    /// before the crash (not yet in session.json) must not be overwritten by the resumed recording's.
    @Test func aResumeSkipsAnIndexWhoseArchiveIsOnDisk() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try writeSentinel(h, alive: 20)
        let dir = outDir(s)
        try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        try Data().write(to: dir.appendingPathComponent("sess-1.m4a"))
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.first?.baseName == "sess-2")
        #expect(RecordingSentinel.read(directory: h.tmp)?.chunkIndex == 2)
    }

    /// The gap starts when capture actually stopped: the orphan chunk's last write — `lastAliveAt` can be
    /// up to the 60 s refresh interval early (C7/C9).
    @Test func theGapStartsWhenTheOrphanChunkWasLastWritten() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try writeSentinel(h, alive: 40)
        let wav = outDir(s).appendingPathComponent("sess-0.wav")
        try Harness.headerOnlyWAV().write(to: wav)
        let sealed = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 12).rounded(.down))
        try FileManager.default.setAttributes([.modificationDate: sealed], ofItemAtPath: wav.path)
        await h.coordinator.recoverAtLaunch()
        let gap = try #require(await h.runner.chunkProcessor?.getSessionState().gaps.first)
        #expect(abs(gap.start.timeIntervalSince(sealed)) < 1)
        #expect(h.appState.activeAlarms[.recordingResumedWithGap]?.message.hasPrefix("Parley crashed at \(RecoveryMessages.clock(sealed))") == true)
    }

    /// Same for the STOPPED time of a salvage: taken before the salvage archives (deletes) the orphan.
    @Test func theStoppedTimeIsWhenTheOrphanChunkWasLastWritten() async throws {
        let h = try Harness()
        let s = try writeSentinel(h, alive: 900)
        let wav = outDir(s).appendingPathComponent("sess-0.wav")
        try Harness.headerOnlyWAV().write(to: wav)
        let sealed = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 300).rounded(.down))
        try FileManager.default.setAttributes([.modificationDate: sealed], ofItemAtPath: wav.path)
        await h.coordinator.recoverAtLaunch()
        let message = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(message.hasPrefix("Recording STOPPED at \(RecoveryMessages.clock(sealed))"))
        #expect(message.contains("The 1 chunk recorded before it was transcribed to sess.json"), "the orphan was consumed (41c): \(message)")
    }

    /// A resume whose pipeline cannot be built after the helper started: the helper is stopped (bounded)
    /// and the session salvaged, loudly — never a capturing helper behind an idle app.
    @Test func aResumeWhoseSetupFailsStopsTheHelperAndSalvages() async throws {
        let h = try Harness()
        _ = try writeSentinel(h, alive: 10)
        h.runner.failSetupForTesting = true
        h.client.stopResult = AudioPaths(systemAudio: h.tmp.appendingPathComponent("x.wav"), micAudio: h.tmp.appendingPathComponent("x_mic.wav"))
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.count == 1 && h.client.stopCalls == 1)
        #expect(h.appState.isIdle && h.appState.activeAlarms[.recordingStopped] != nil)
        #expect(h.client.captureEndedCalls == 1)
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
    }

    /// §8.9: an unreachable folder (an unplugged drive) leaves the sentinel, alarms, and retries; the
    /// alarm clears once the folder is back — it outlives recordings, so it must never stick.
    private func writeUnreachableSentinel(_ h: Harness) throws -> URL {
        let locked = h.tmp.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let dir = locked.appendingPathComponent("day")
        let sentinel = RecordingSentinel(
            startedAt: Date(), sessionName: "T",
            systemAudioPath: dir.appendingPathComponent("sess-0.wav").path,
            micAudioPath: dir.appendingPathComponent("sess-0_mic.wav").path, segment: 1, chunkIndex: 0)
        try RecordingSentinel.write(sentinel, directory: h.tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        return locked
    }

    @Test func anUnreachableFolderWaitsAndRecoversWhenItReturns() async throws {
        let h = try Harness()
        let locked = try writeUnreachableSentinel(h)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        await h.coordinator.recoverAtLaunch()
        #expect(h.appState.activeAlarms[.recordingFolderUnavailable] != nil)
        #expect(RecordingSentinel.readPending(directory: h.tmp).count == 1, "kept: the data may be on the missing drive")
        #expect(h.client.captureEndedCalls == 1 && h.appState.isIdle, "no capture: detection disarmed")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)   // the drive is back
        await h.coordinator.retryPendingSessions()   // the volume-mounted event
        #expect(h.appState.activeAlarms[.recordingFolderUnavailable] == nil, "cleared: never a stuck false alarm")
        #expect(h.appState.activeAlarms[.recordingStopped] != nil)
        #expect(RecordingSentinel.readPending(directory: h.tmp).isEmpty)
    }

    /// The retry never acts while a recording runs or starts: the sentinel on disk would be ITS own.
    @Test func theFolderRetryNeverRunsDuringARecording() async throws {
        let h = try Harness()
        let locked = try writeUnreachableSentinel(h)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        await h.coordinator.recoverAtLaunch()
        h.appState.phase = .recording(since: Date())   // a recording started meanwhile
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        await h.coordinator.retryPendingSessions()   // a volume mounted mid-recording
        #expect(h.client.isCapturingCalls == 1, "not even the ping")
        #expect(h.appState.activeAlarms[.recordingStopped] == nil && RecordingSentinel.readPending(directory: h.tmp).count == 1)

        h.appState.phase = .idle
        var waited = 0
        while h.appState.activeAlarms[.recordingStopped] == nil, waited < 400 { try await Task.sleep(nanoseconds: 5_000_000); waited += 1 }
        #expect(h.appState.activeAlarms[.recordingStopped] != nil && h.appState.activeAlarms[.recordingFolderUnavailable] == nil)
    }
}

// MARK: - Disk (L8, §8.7)

@MainActor
@Suite struct RecordingCoordinatorDiskTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
    }

    @Test func startIsRefusedWhenTheDiskIsFull() async throws {
        let h = try Harness()
        let coordinator = RecordingCoordinator(
            appState: h.appState, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { h.notified.value.append(($0, $1)) }, notifyCritical: { _, _ in },
            presentTranscript: { _, _ in }, recordingMicrophone: h.recordingMic, freeBytesProvider: { _ in 1_000_000 })
        await coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(h.client.startCalls.isEmpty && h.appState.isIdle)
        #expect(h.notified.value.first?.title == "Recording not started")
        #expect(h.notified.value.first?.body.contains("MB free") == true)
        #expect(h.appState.errorMessage == h.notified.value.first?.body, "visible with notifications off (34)")
        #expect(RecordingSentinel.read(directory: h.tmp) == nil && !coordinator.isStartInFlight)
    }

    /// A recording folder not created yet (a fresh install, a deleted folder) is still checked: the free
    /// space is read on its nearest existing ancestor, never skipped as "unknown".
    @Test func theStartCheckReadsTheNearestExistingFolder() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec/not-yet").path }
        let seen = Harness.Box<URL?>(nil)
        let coordinator = RecordingCoordinator(
            appState: h.appState, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { h.notified.value.append(($0, $1)) }, notifyCritical: { _, _ in },
            presentTranscript: { _, _ in }, recordingMicrophone: h.recordingMic,
            freeBytesProvider: { url in seen.value = url; return 1_000_000 })
        await coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        // `rec/not-yet` does not exist: its nearest existing ancestor, symlinks resolved (/var → /private/var).
        #expect(seen.value?.path == h.tmp.resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(h.client.startCalls.isEmpty)
    }

    /// 31: a recording folder reached through a symlink is read where it really is.
    @Test func theStartCheckResolvesSymlinks() async throws {
        let h = try Harness()
        let real = h.tmp.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = h.tmp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        h.config.update { $0.recordingDirectory = link.path }
        let seen = Harness.Box<URL?>(nil)
        let coordinator = RecordingCoordinator(
            appState: h.appState, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { h.notified.value.append(($0, $1)) }, notifyCritical: { _, _ in },
            presentTranscript: { _, _ in }, recordingMicrophone: h.recordingMic,
            freeBytesProvider: { url in seen.value = url; return 1_000_000 })
        await coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(seen.value?.path == real.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    /// 32/34: a recording folder on a drive that is not there is named as the cause, before any disk
    /// read — and the refusal is visible in the app even with notifications off.
    @Test func aStartIsRefusedWhenTheRecordingFolderIsUnreachable() async throws {
        let h = try Harness()
        let locked = h.tmp.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        h.config.update { $0.recordingDirectory = locked.appendingPathComponent("Recordings").path }
        let read = Harness.Box(false)
        let coordinator = RecordingCoordinator(
            appState: h.appState, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { h.notified.value.append(($0, $1)) }, notifyCritical: { _, _ in },
            presentTranscript: { _, _ in }, recordingMicrophone: h.recordingMic,
            freeBytesProvider: { _ in read.value = true; return .max })
        await coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(h.client.startCalls.isEmpty && !read.value, "refused before the disk read")
        #expect(h.notified.value.first?.title == "Recording not started")
        #expect(h.notified.value.first?.body.contains("isn’t reachable") == true)
        #expect(h.appState.errorMessage == h.notified.value.first?.body)
    }

    /// 33: the start's disk read runs off the main actor (a hung network volume must not freeze the UI).
    @Test func theStartDiskReadIsOffTheMainActor() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        let onMain = Harness.Box<Bool?>(nil)
        let coordinator = RecordingCoordinator(
            appState: h.appState, captureClient: h.client, transcriptionRunner: h.runner, configManager: h.config,
            sentinelDirectory: h.tmp, notify: { h.notified.value.append(($0, $1)) }, notifyCritical: { _, _ in },
            presentTranscript: { _, _ in }, recordingMicrophone: h.recordingMic,
            freeBytesProvider: { _ in onMain.value = Thread.isMainThread; return 1_000_000 })
        await coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(onMain.value == false)
    }

    @Test func aRotationFailureRaisesTheAlarmAndADeadCaptureBecomesACrash() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }   // never the real ~/Documents/Recordings
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try FileManager.default.createDirectory(at: try #require(h.client.startCalls.first).outputDirectory, withIntermediateDirectories: true)
        h.client.rotateError = FakeCaptureError()
        h.runner.chunkRotator?.rotateNow()
        await Harness.until { h.appState.activeAlarms[.rotationFailed] != nil }
        #expect(h.appState.activeAlarms[.rotationFailed] != nil)
        #expect(h.client.recordedEvents.contains { $0.kind == .rotationFailed })
        #expect(h.client.startCalls.count == 1, "an ordinary rotate failure is not a crash")
        h.client.rotateError = NoCaptureError()
        h.runner.chunkRotator?.rotateNow()
        await Harness.until { h.client.startCalls.count == 2 }
        #expect(h.client.startCalls.count == 2, "\"No capture in progress\" means the capture is dead: the crash path restarts it")
    }

    /// A rotation that works again proves rotation works: the rotation alarm clears.
    @Test func aSuccessfulRotationClearsTheRotationAlarm() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.client.rotateError = FakeCaptureError()
        await h.runner.chunkRotator?.rotateForTesting()
        #expect(h.appState.activeAlarms[.rotationFailed] != nil)
        h.client.rotateError = nil
        await h.runner.chunkRotator?.rotateForTesting()
        #expect(h.appState.activeAlarms[.rotationFailed] == nil)
    }

    /// §8.7: below one chunk at a rotation → `diskLow` (recorded); it clears only above two chunks
    /// (hysteresis), never flapping at the one-chunk line.
    @Test func aLowDiskAtRotationRaisesDiskLowWithHysteresis() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let chunk = DiskSpaceCheck.bytesPerChunk(chunkMinutes: h.config.config.validatedChunkDuration)
        h.freeBytes.value = chunk - 1
        await h.runner.chunkRotator?.rotateForTesting()
        #expect(h.appState.activeAlarms[.diskLow] != nil)
        #expect(h.client.recordedEvents.contains { $0.kind == .diskLow && $0.severity == .warning && $0.detail["free_mb"] != nil })
        h.freeBytes.value = chunk + 1
        await h.runner.chunkRotator?.rotateForTesting()
        #expect(h.appState.activeAlarms[.diskLow] != nil, "still low: under two chunks")
        h.freeBytes.value = 2 * chunk
        await h.runner.chunkRotator?.rotateForTesting()
        #expect(h.appState.activeAlarms[.diskLow] == nil)
    }

    /// R2's hook: a session.json write that fails (here a capture gap's) is a sticky alarm and a
    /// provenance event — nil chunk = a session-level write.
    @Test func aSessionWriteFailureRaisesTheAlarmAndIsRecorded() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let outDir = try #require(h.client.startCalls.first).outputDirectory
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: outDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outDir.path) }
        await h.runner.recordCaptureGap(CaptureGap(start: Date().addingTimeInterval(-5), end: Date(), reason: "sleep"))
        #expect(h.appState.activeAlarms[.sessionWriteFailed] != nil)
        #expect(h.client.recordedEvents.contains { $0.kind == .sessionWriteFailed && $0.detail["chunk"] == "session" })
    }
}

// MARK: - Deadlines; the sentinel outlives finalize (L9, §8.8)

@MainActor
@Suite struct RecordingCoordinatorDeadlineTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
    }

    /// L13 / #194 / #195: a crash during transcription must still find the sentinel.
    @Test func stopKeepsTheSentinelUntilTheTranscriptExists() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }   // never the real ~/Documents/Recordings
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let call = try #require(h.client.startCalls.first)
        try FileManager.default.createDirectory(at: call.outputDirectory, withIntermediateDirectories: true)
        let sys = call.outputDirectory.appendingPathComponent(call.baseName + ".wav")
        let mic = call.outputDirectory.appendingPathComponent(call.baseName + "_mic.wav")
        // Header-only: processing them never loads a model (the test stays hermetic and fast).
        try Harness.headerOnlyWAV().write(to: sys); try Harness.headerOnlyWAV().write(to: mic)
        h.client.stopResult = AudioPaths(systemAudio: sys, micAudio: mic)
        h.runner.finalizeDelayForTesting = .milliseconds(400)   // R0 seam

        let stopping = Task { await h.coordinator.stopRecording() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(RecordingSentinel.read(directory: h.tmp) != nil, "still there while finalize runs")
        #expect(RecordingSentinel.read(directory: h.tmp)?.stopping == true, "and marked: a crash now is salvaged, never resumed")
        await stopping.value
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
        #expect(h.presented.value.count == 1)
    }

    /// Council B-I3: no rotation may race the helper's stop. The timer stops, and a rotation already in
    /// flight completes, BEFORE the helper is asked to stop.
    @Test func stopWaitsForARotationInFlightBeforeAskingTheHelper() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let rotator = try #require(h.runner.chunkRotator)
        let released = Harness.Box(false)
        h.client.onRotate = { while !released.value { await Task.yield() } }
        rotator.rotateNow()
        for _ in 0..<20 { await Task.yield() }
        #expect(h.client.rotateCalls == 1, "a rotation is in flight")
        let seenAtStop = Harness.Box<(index: Int, timerLive: Bool)?>(nil)
        h.client.onStop = { seenAtStop.value = (rotator.currentChunkInfo.index, rotator.activeTimerForTesting != nil) }
        let stopping = Task { await h.coordinator.stopRecording() }
        for _ in 0..<20 { await Task.yield() }
        #expect(h.client.stopCalls == 0, "the helper is not asked to stop while a rotation is in flight")
        released.value = true
        await stopping.value
        #expect(seenAtStop.value?.index == 1, "the rotation finished first")
        #expect(seenAtStop.value?.timerLive == false, "the rotation timer stopped before the helper's stop")
    }

    /// Council B-I3 / H2: the helper refuses a rotation while it is stopping. That is the recording ending,
    /// not a dead capture: no crash restart, no rotation alarm.
    @Test func aRotationRefusedWhileStoppingIsNotACrash() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.client.rotateError = RefusedStoppingError()
        await h.runner.chunkRotator?.rotateForTesting()
        for _ in 0..<50 { await Task.yield() }
        #expect(h.client.startCalls.count == 1 && h.appState.activeAlarms[.rotationFailed] == nil)
    }

    /// The one place that reads the helper's rotate replies (to be pointed at H2's `CaptureReplies`).
    @Test func rotateRepliesAreClassifiedInOnePlace() {
        #expect(RecordingCoordinator.rotateFailure("No capture in progress") == .captureDead)
        #expect(RecordingCoordinator.rotateFailure("refused: stopping") == .refusedWhileStopping)
        #expect(RecordingCoordinator.rotateFailure("XPC connection failed: boom") == .other)
    }

    /// L8 review: a rotate that fails while a Stop is in flight (the drain before the helper's stop) is
    /// the recording ending: no rotationFailed anomaly, no alarm.
    @Test func aRotationFailingDuringAStopIsNotAnAnomaly() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let released = Harness.Box(false)
        h.client.onRotate = { while !released.value { await Task.yield() } }
        h.client.rotateError = NoCaptureError()
        h.runner.chunkRotator?.rotateNow()
        for _ in 0..<20 { await Task.yield() }
        let stopping = Task { await h.coordinator.stopRecording() }
        for _ in 0..<20 { await Task.yield() }
        released.value = true
        await stopping.value
        for _ in 0..<50 { await Task.yield() }
        #expect(!h.client.recordedEvents.contains { $0.kind == .rotationFailed })
        #expect(h.client.startCalls.count == 1, "no crash restart during the stop")
    }

    /// L8 review: nor during a crash recovery (the restart owns the capture then).
    @Test func aRotationFailingDuringARecoveryIsNotAnAnomaly() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.coordinator.recoveryInFlight = true
        h.client.rotateError = FakeCaptureError()
        await h.runner.chunkRotator?.rotateForTesting()
        h.coordinator.recoveryInFlight = false
        #expect(!h.client.recordedEvents.contains { $0.kind == .rotationFailed })
        #expect(h.appState.activeAlarms[.rotationFailed] == nil)
    }

    /// §8.8 + addendum: a start that the audio system never answers ends at the deadline — honestly, with
    /// no helper left capturing, and the next Start is possible at once.
    @Test func aStartTheHelperNeverAnswersEndsAtTheDeadline() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        h.coordinator.startDeadline = .milliseconds(200)
        h.client.stopResult = AudioPaths(systemAudio: h.tmp.appendingPathComponent("a.wav"), micAudio: h.tmp.appendingPathComponent("a_mic.wav"))
        let stalled = Harness.Box(true)
        h.client.onStartAsync = { if stalled.value { try? await Task.sleep(for: .seconds(2)) } }
        let began = ContinuousClock.now
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "mic-1")
        #expect(ContinuousClock.now - began < .milliseconds(500), "bounded by the 200 ms deadline, never the helper's 2 s (L9 review 50)")
        #expect(!h.coordinator.isStartInFlight, "cleared on the timeout path")
        #expect(h.appState.isIdle && RecordingSentinel.read(directory: h.tmp) == nil)
        #expect(h.notified.value.last?.title == "Recording Failed")
        #expect(h.notified.value.last?.body == "Parley couldn’t start recording — the audio system didn’t respond.")
        #expect(h.client.stopCalls == 1, "a bounded stop: a start that commits late is aborted, never left capturing")
        #expect(h.recordingMic.current == .none)
        #expect(h.client.recordedEvents.contains { $0.kind == .xpcTimeout })

        stalled.value = false
        await h.coordinator.startRecording(sessionName: "b", microphoneDeviceId: nil)
        #expect(h.appState.isRecording && h.client.startCalls.count == 2)
    }

    /// Addendum: the deadline covers the WHOLE start, the pre-flight IOKit/CoreAudio lookup included.
    @Test func aStalledPreflightLookupEndsAtTheDeadline() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        h.coordinator.startDeadline = .milliseconds(150)
        h.coordinator.preflight = { _ in Thread.sleep(forTimeInterval: 0.6); return (false, false) }
        let began = ContinuousClock.now
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(ContinuousClock.now - began < .milliseconds(450), "bounded by the 150 ms deadline, never the 600 ms lookup")
        #expect(!h.coordinator.isStartInFlight && h.appState.isIdle)
        #expect(h.client.startCalls.isEmpty && h.client.stopCalls == 0, "the helper was never involved")
        #expect(h.notified.value.last?.body == "Parley couldn’t start recording — the audio system didn’t respond.")
    }

    /// §8.8 (council B-I1): the stop has a deadline. On timeout the session is salvaged from disk and the
    /// user told so — never stuck on "Finishing…".
    @Test func aStopTheHelperNeverAnswersIsSalvagedAtTheDeadline() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.coordinator.stopDeadline = .milliseconds(200)
        h.client.onStop = { try? await Task.sleep(for: .seconds(2)) }
        h.client.stopResult = AudioPaths(systemAudio: URL(fileURLWithPath: "/nonexistent/a.wav"), micAudio: URL(fileURLWithPath: "/nonexistent/a_mic.wav"))
        let began = ContinuousClock.now
        await h.coordinator.stopRecording()
        #expect(ContinuousClock.now - began < .milliseconds(500), "bounded by the 200 ms deadline, never the helper's 2 s")
        #expect(h.appState.isIdle, "never left on Finishing…")
        let critical = try #require(h.criticals.value.first)
        // The title follows what the salvage wrote (L6); the body says why the stop failed.
        #expect(critical.body.hasPrefix("Stopping the recording failed (the capture helper did not respond within"), "\(critical.body)")
        #expect(RecordingSentinel.read(directory: h.tmp) == nil && h.client.recordedEvents.contains { $0.kind == .xpcTimeout })
    }

    /// L9 review 45: a stop that times out may leave the helper capturing. The XPC connection is dropped
    /// BEFORE the salvage — the helper's invalidation handler stops and finalizes its capture — and the
    /// sentinel stays marked `stopping` meanwhile, so a crash mid-salvage is still salvaged at relaunch.
    @Test func aStopTimeoutDropsTheConnectionBeforeTheSalvage() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "mic-1")
        h.coordinator.stopDeadline = .milliseconds(150)
        h.client.onStop = { try? await Task.sleep(for: .seconds(2)) }
        let runner = h.runner, tmp = h.tmp, mic = h.recordingMic
        let atDrop = Harness.Box<(stopping: Bool?, pipelineUp: Bool, micMarked: Bool)?>(nil)
        h.client.onDropConnection = {
            atDrop.value = (RecordingSentinel.read(directory: tmp)?.stopping, runner.chunkProcessor != nil, mic.current != nil)
        }
        await h.coordinator.stopRecording()
        #expect(h.client.droppedConnections == 1)
        #expect(atDrop.value?.stopping == true, "the sentinel is still there, marked stopping")
        #expect(atDrop.value?.pipelineUp == true, "dropped before the salvage tore the pipeline down")
        #expect(atDrop.value?.micMarked == true, "the mic is released only once the helper was told to let go")
        #expect(h.appState.isIdle)
    }

    /// L9 review 47: the honest message is shown at the start's deadline, BEFORE the post-timeout stop — and
    /// the start stays in flight (no new Start) until that stop returns.
    @Test func theStartTimeoutMessageComesBeforeItsStop() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        h.coordinator.startDeadline = .milliseconds(150)
        h.client.stopResult = AudioPaths(systemAudio: h.tmp.appendingPathComponent("a.wav"), micAudio: h.tmp.appendingPathComponent("a_mic.wav"))
        h.client.onStartAsync = { try? await Task.sleep(for: .seconds(2)) }
        let appState = h.appState, coordinator = h.coordinator
        let atStop = Harness.Box<(message: String?, inFlight: Bool)?>(nil)
        h.client.onStop = { atStop.value = (appState.errorMessage, coordinator.isStartInFlight) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(atStop.value?.message == "Parley couldn’t start recording — the audio system didn’t respond.")
        #expect(atStop.value?.inFlight == true, "held until the stop returns")
        #expect(!h.coordinator.isStartInFlight)
    }

    /// L9 review 45: a start that timed out AND whose bounded stop timed out too — the last lever is the
    /// connection: dropped, so the helper's invalidation handler stops it. The sentinel and the mic stay.
    @Test func aStartWhoseStopAlsoTimesOutDropsTheConnection() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        h.coordinator.startDeadline = .milliseconds(150)
        h.coordinator.helperStopDeadline = .milliseconds(100)
        h.client.onStartAsync = { try? await Task.sleep(for: .seconds(2)) }
        h.client.onStop = { try? await Task.sleep(for: .seconds(2)) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "mic-1")
        #expect(h.client.stopCalls == 1 && h.client.droppedConnections == 1)
        #expect(RecordingSentinel.read(directory: h.tmp) != nil && h.recordingMic.current == .some("mic-1"))
    }

    /// L9 review 44: the crash restart's start timed out — it may still commit, so the helper is stopped
    /// (bounded) before the app goes idle, exactly as at the recording's own start.
    @Test func aCrashRestartWhoseStartTimesOutStopsTheHelper() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "mic-1")
        h.client.startError = CaptureCallTimeout(call: "start", seconds: 15)
        h.client.stopResult = AudioPaths(systemAudio: h.tmp.appendingPathComponent("a.wav"), micAudio: h.tmp.appendingPathComponent("a_mic.wav"))
        await h.coordinator.handleXPCCrash()
        #expect(h.client.stopCalls == 1, "never a helper left capturing behind an idle app")
        #expect(h.appState.isIdle && h.criticals.value.map(\.title) == ["Recording Failed"])
        #expect(RecordingSentinel.read(directory: h.tmp) == nil && h.recordingMic.current == .none)
    }

    /// L9 review 44 + 45: the crash restart's start timed out and the helper will not stop either: the
    /// connection is dropped, and the sentinel (marked stopping) and the mic are kept for the next launch.
    @Test func aCrashRestartWhoseHelperWillNotStopKeepsTheSentinel() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "mic-1")
        h.client.startError = CaptureCallTimeout(call: "start", seconds: 15)
        h.coordinator.helperStopDeadline = .milliseconds(100)
        h.client.onStop = { try? await Task.sleep(for: .seconds(2)) }
        await h.coordinator.handleXPCCrash()
        #expect(h.client.stopCalls == 1 && h.client.droppedConnections == 1)
        #expect(h.appState.isIdle)
        #expect(RecordingSentinel.read(directory: h.tmp)?.stopping == true, "kept, and never resumed: salvaged at the next launch")
        #expect(h.recordingMic.current == .some("mic-1"))
    }
}

// MARK: - Sleep, wake, power-off, quit (L10, §8.10)

@MainActor
@Suite struct RecordingCoordinatorSystemEventTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
    }

    @Test func sleepAndWakeAreRecordedAsAGapAndForceARotation() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }   // never the real ~/Documents/Recordings
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try FileManager.default.createDirectory(at: try #require(h.client.startCalls.first).outputDirectory, withIntermediateDirectories: true)
        let t0 = Date(timeIntervalSince1970: 1_000)
        h.coordinator.systemWillSleep(at: t0)
        h.coordinator.systemDidWake(at: t0 + 120)
        for _ in 0..<50 { await Task.yield() }
        #expect(h.client.powerEvents == ["sleep", "wake"])
        let powerKinds: [CaptureEventKind] = h.client.recordedEvents.map(\.kind).filter { $0 == .systemSleep || $0 == .systemWake }
        #expect(powerKinds == [.systemSleep, .systemWake])
        #expect(h.client.rotateCalls == 1, "wake forces a rotation")
        let gaps = try #require(await h.runner.chunkProcessor?.getSessionState().gaps)
        #expect(gaps.count == 1 && gaps[0].reason == "sleep" && gaps[0].seconds == 120)
        #expect(h.appState.interruptionWarning == "Recording restarted — waiting for audio…")
    }

    /// v3 note (H7): the helper pairs its sleep-time `cancelAll()` with the wake's `trigger(.wake)` — a
    /// "wake" must never overtake a "sleep" still being delivered.
    @Test func aWakeIsNeverDeliveredBeforeItsSleep() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.client.onPowerEvent = { kind in if kind == "sleep" { try? await Task.sleep(for: .milliseconds(80)) } }
        h.coordinator.systemWillSleep(at: Date())
        h.coordinator.systemDidWake(at: Date())
        var waited = 0
        while h.client.powerEvents.count < 2, waited < 200 { try await Task.sleep(nanoseconds: 5_000_000); waited += 1 }
        #expect(h.client.powerEvents == ["sleep", "wake"])
    }

    @Test func sleepAndWakeOutsideARecordingDoNothing() async throws {
        let h = try Harness()
        h.coordinator.systemWillSleep(at: Date())
        h.coordinator.systemDidWake(at: Date())
        for _ in 0..<50 { await Task.yield() }
        #expect(h.client.powerEvents.isEmpty && h.client.recordedEvents.isEmpty)
    }

    /// §8.10: the Mac does not idle-sleep while recording (a lid close is the user's call: recorded as a
    /// gap, not fought); the assertion ends with the recording, whatever ended it.
    @Test func idleSleepIsPreventedOnlyWhileRecording() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        #expect(!h.coordinator.preventsIdleSleep)
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(h.coordinator.preventsIdleSleep)
        h.client.stopError = FakeCaptureError()
        await h.coordinator.stopRecording()
        for _ in 0..<20 { await Task.yield() }
        #expect(!h.coordinator.preventsIdleSleep)
    }

    @Test func quitWhileRecordingStopsFirstOnlyWhenConfirmed() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(await h.coordinator.prepareForQuit(confirm: { false }) == false)
        #expect(h.client.stopCalls == 0 && h.appState.isRecording)
        #expect(await h.coordinator.prepareForQuit(confirm: { true }) == true)
        #expect(h.client.stopCalls == 1)
        let idle = try Harness()
        #expect(await idle.coordinator.prepareForQuit(confirm: { false }) == true, "idle: nothing to confirm")
    }

    /// L5 review: with no `.starting` phase the phase is `.idle` while a start is in flight. A quit then
    /// is a quit mid-recording: confirmed first, and it waits for the start, then stops the recording.
    @Test func quitDuringAStartIsConfirmedWaitsForItAndStops() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        let released = Harness.Box(false)
        h.client.onStartAsync = { while !released.value { await Task.yield() } }
        let coordinator = h.coordinator
        let starting = Task { await coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil) }
        for _ in 0..<20 { await Task.yield() }
        #expect(h.coordinator.isStartInFlight && h.appState.isIdle)
        #expect(await h.coordinator.prepareForQuit(confirm: { false }) == false, "a start in flight is busy, like a recording")
        let asked = Harness.Box(false)
        let quitting = Task { await coordinator.prepareForQuit(confirm: { asked.value = true; return true }) }
        for _ in 0..<20 { await Task.yield() }
        #expect(asked.value && h.client.stopCalls == 0, "confirmed, and waiting for the start")
        released.value = true
        await starting.value
        #expect(await quitting.value == true)
        #expect(h.client.stopCalls == 1, "the recording the start began is stopped before the quit")
    }

    @Test func powerOffStopsARecording() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.systemWillPowerOff()
        #expect(h.client.stopCalls == 0, "idle: nothing to stop")
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        await h.coordinator.systemWillPowerOff()
        #expect(h.client.stopCalls == 1 && !h.appState.isRecording)
    }

    /// L5 review: logout or shutdown while a start is in flight waits for it, then stops the recording.
    @Test func powerOffDuringAStartWaitsForItAndStops() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        let released = Harness.Box(false)
        h.client.onStartAsync = { while !released.value { await Task.yield() } }
        let coordinator = h.coordinator
        let starting = Task { await coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil) }
        for _ in 0..<20 { await Task.yield() }
        let poweringOff = Task { await coordinator.systemWillPowerOff() }
        for _ in 0..<20 { await Task.yield() }
        #expect(h.client.stopCalls == 0)
        released.value = true
        await starting.value
        await poweringOff.value
        #expect(h.client.stopCalls == 1 && !h.appState.isRecording)
    }
}

// MARK: - The completion notice (L12, §7.3, council C-C2)

@MainActor
@Suite struct RecordingCoordinatorCompletionNoticeTests {
    /// A plain "Transcription Complete" only when the transcript is truly clean: processing problems and
    /// an empty transcript are named.
    @Test func completionNoticeNamesProcessingProblemsAndEmptyTranscripts() async throws {
        let h = try Harness()
        let url = h.tmp.appendingPathComponent("done.json")
        // `problemChunkCount` counts distinct chunks with a content-affecting issue in `processing_issues`.
        try JSONSerialization.data(withJSONObject: [
            "metadata": ["processing_issues": [["chunk": 0, "code": "asr_failed"], ["chunk": 1, "code": "asr_failed"]],
                         "capture_provenance": ["quality_anomaly_count": 0]] as [String: Any],
            "segments": [["start": 0.0, "end": 1.0, "text": "x", "speaker": "S"]],
        ]).write(to: url)
        h.appState.phase = .transcribing(progress: "")
        await h.coordinator.presentCompletedTranscription(TranscriptionResult(jsonPath: url))
        #expect(h.notified.value.last?.title == "Transcription Complete — 2 chunks had processing problems")
        #expect(h.notified.value.last?.body == "done.json — 2 chunks had processing problems")
        try JSONSerialization.data(withJSONObject: ["metadata": [:] as [String: Any], "segments": [] as [Any]]).write(to: url)
        h.appState.phase = .transcribing(progress: "")
        await h.coordinator.presentCompletedTranscription(TranscriptionResult(jsonPath: url))
        #expect(h.notified.value.last?.title == "Transcription Complete — no speech was transcribed")
    }

    @Test func aCleanTranscriptSaysTranscriptionComplete() async throws {
        let h = try Harness()
        let url = h.tmp.appendingPathComponent("clean.json")
        try JSONSerialization.data(withJSONObject: [
            "metadata": ["capture_provenance": ["quality_anomaly_count": 0]] as [String: Any],
            "segments": [["start": 0.0, "end": 1.0, "text": "x", "speaker": "S"]],
        ]).write(to: url)
        h.appState.phase = .transcribing(progress: "")
        await h.coordinator.presentCompletedTranscription(TranscriptionResult(jsonPath: url))
        #expect(h.notified.value.last?.title == "Transcription Complete")
        #expect(h.notified.value.last?.body == "clean.json")
    }
}

// MARK: - L follow-ups: pending sessions, folder events, ghost mounts, a helper that will not stop

@MainActor
@Suite struct RecordingCoordinatorPendingSessionTests {
    private func pending(_ h: Harness) -> [RecordingSentinel] { RecordingSentinel.readPending(directory: h.tmp) }

    /// A sentinel in the slot whose folder is unreachable (its parent is not writable).
    private func writeUnreachableSentinel(_ h: Harness, name: String = "sess", folder: String = "locked") throws -> (sentinel: RecordingSentinel, locked: URL) {
        let locked = h.tmp.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let dir = locked.appendingPathComponent("day")
        let sentinel = RecordingSentinel(
            startedAt: Date(), sessionName: "T",
            systemAudioPath: dir.appendingPathComponent("\(name)-0.wav").path,
            micAudioPath: dir.appendingPathComponent("\(name)-0_mic.wav").path, segment: 1, chunkIndex: 0)
        try RecordingSentinel.write(sentinel, directory: h.tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        return (sentinel, locked)
    }

    private func unlock(_ folder: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        var waited = 0
        while !condition(), waited < 400 { try await Task.sleep(nanoseconds: 5_000_000); waited += 1 }
    }

    /// 24: waiting sessions are a LIST beside the sentinel. A later recording's sentinel never takes their
    /// place, and each one is salvaged when its folder returns.
    @Test func waitingSessionsAreAListALaterRecordingNeverOverwrites() async throws {
        let h = try Harness()
        let (first, lockedA) = try writeUnreachableSentinel(h, name: "a", folder: "lockedA")
        defer { unlock(lockedA) }
        await h.coordinator.recoverAtLaunch()
        #expect(pending(h).map(\.sessionKey) == [first.sessionKey])
        #expect(RecordingSentinel.read(directory: h.tmp) == nil, "the slot is free for the next recording")
        #expect(h.appState.activeAlarms[.recordingFolderUnavailable] != nil)

        // A later recording crashed too, its folder unreachable as well: the next launch finds both.
        let (second, lockedB) = try writeUnreachableSentinel(h, name: "b", folder: "lockedB")
        defer { unlock(lockedB) }
        await h.coordinator.recoverAtLaunch()
        #expect(Set(pending(h).map(\.sessionKey)) == [first.sessionKey, second.sessionKey])

        unlock(lockedA)
        await h.coordinator.retryPendingSessions()   // a volume mounted
        #expect(pending(h).map(\.sessionKey) == [second.sessionKey], "salvaged as soon as ITS folder is back")
        #expect(h.appState.activeAlarms[.recordingFolderUnavailable] != nil, "one is still waiting")
        unlock(lockedB)
        await h.coordinator.retryPendingSessions()
        #expect(pending(h).isEmpty && h.appState.activeAlarms[.recordingFolderUnavailable] == nil)
        #expect(h.appState.activeAlarms[.recordingStopped] != nil)
    }

    /// 35: no timer. Nothing happens until an event — a volume mount, a wake, a launch, a recording's end.
    @Test func theFolderRetryIsEventDrivenNeverATimer() async throws {
        let h = try Harness()
        let (_, locked) = try writeUnreachableSentinel(h)
        defer { unlock(locked) }
        await h.coordinator.recoverAtLaunch()
        unlock(locked)
        try await Task.sleep(for: .milliseconds(150))
        #expect(pending(h).count == 1 && h.client.isCapturingCalls == 1, "no poll: nothing ran by itself")
        await h.coordinator.retryPendingSessions()
        #expect(pending(h).isEmpty && h.appState.activeAlarms[.recordingStopped] != nil)
    }

    /// 35/38: an event during a recording (the slot is that recording's) waits, and runs when it ends.
    @Test func aRetryAskedForDuringARecordingRunsWhenItEnds() async throws {
        let h = try Harness()
        let (_, locked) = try writeUnreachableSentinel(h)
        defer { unlock(locked) }
        await h.coordinator.recoverAtLaunch()
        unlock(locked)
        h.appState.phase = .recording(since: Date())
        await h.coordinator.retryPendingSessions()
        #expect(pending(h).count == 1 && h.client.isCapturingCalls == 1, "never during a recording, not even the ping")
        h.appState.phase = .idle
        try await waitUntil { pending(h).isEmpty }
        #expect(pending(h).isEmpty)
    }

    /// 38: a Start pressed during the launch ping owns the app: the session is kept for later, never
    /// resumed on top of that start.
    @Test func aStartPressedDuringTheLaunchPingDefersTheSession() async throws {
        let h = try Harness()
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-10)
        s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        let coordinator = h.coordinator
        h.client.onIsCapturing = { coordinator.announceStart() }   // the user starts a recording meanwhile
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.isEmpty, "no resume races the user's start")
        #expect(pending(h).map(\.sessionKey) == [s.sessionKey])
        #expect(h.coordinator.isStartInFlight, "the user's start is left alone")
    }

    /// 40: a `stopping` sentinel whose helper will not stop is not salvaged while its file may still be
    /// written. It is kept, the user told, and the next event finishes it once the helper lets go.
    @Test func aStoppingSessionWhoseHelperWillNotStopIsKeptNeverSalvagedLive() async throws {
        let h = try Harness()
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID(); s.stopping = true
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.isCapturingResult = true
        h.coordinator.helperStopDeadline = .milliseconds(150)
        let hang = Harness.Box(true)
        h.client.onStop = { if hang.value { try? await Task.sleep(for: .seconds(1)) } }
        await h.coordinator.recoverAtLaunch()
        #expect(pending(h).map(\.sessionKey) == [s.sessionKey])
        #expect(h.presented.value.isEmpty && h.client.finalizeCalls.isEmpty, "a file still being written is never salvaged")
        #expect(h.appState.activeAlarms[.recordingStopped]?.message.contains("couldn’t stop the previous recording cleanly") == true)
        #expect(h.client.recordedEvents.contains { $0.kind == .xpcTimeout })

        hang.value = false
        h.client.isCapturingResult = false   // the helper let go
        await h.coordinator.retryPendingSessions()
        #expect(pending(h).isEmpty && !h.client.finalizeCalls.isEmpty, "finished once the helper let go")
    }

    /// 27: a failed start's bounded helper stop that does not answer is never swallowed. The helper may
    /// still hold the mic: the sentinel and the mic marker stay, and it is logged and recorded.
    @Test func aFailedStartWhoseHelperWillNotStopKeepsTheSentinelAndTheMic() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        h.runner.failSetupForTesting = true
        h.coordinator.helperStopDeadline = .milliseconds(150)
        h.client.onStop = { try? await Task.sleep(for: .seconds(1)) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "mic-1")
        #expect(RecordingSentinel.read(directory: h.tmp) != nil, "the next launch sees the capturing helper and handles it")
        #expect(h.recordingMic.current == .some("mic-1"), "the helper may still hold the mic")
        #expect(h.client.recordedEvents.contains { $0.kind == .xpcTimeout && $0.detail["call"] == "stop after failed start" })
        #expect(h.appState.isIdle && !h.coordinator.isStartInFlight && h.notified.value.last?.title == "Recording Failed")
    }

    /// 27: a stop that fails with anything but "not capturing" is recorded too, and keeps the sentinel.
    @Test func aFailedStartWhoseHelperStopErrorsIsRecordedAndKept() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        h.runner.failSetupForTesting = true
        h.client.stopError = FakeCaptureError()
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(h.client.recordedEvents.contains { $0.kind == .streamStopError && $0.detail["call"] == "stop after failed start" })
        #expect(RecordingSentinel.read(directory: h.tmp) != nil)
    }

    /// 25: a legacy (pre-0.6, single-file) recording is never called "no recorded audio": it is kept, and
    /// the message names its folder, not the meeting.
    @Test func aLegacySingleFileRecordingIsNeverCalledNoRecordedAudio() async throws {
        let h = try Harness()
        let outDir = h.tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let sentinel = RecordingSentinel(
            startedAt: Date(), sessionName: "Board meeting",
            systemAudioPath: outDir.appendingPathComponent("board.wav").path,
            micAudioPath: outDir.appendingPathComponent("board_mic.wav").path, segment: 1, chunkIndex: 0)
        try RecordingSentinel.write(sentinel, directory: h.tmp)
        try Data(count: 4096).write(to: URL(fileURLWithPath: sentinel.systemAudioPath))
        await h.coordinator.recoverAtLaunch()
        let message = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(!message.contains("no recorded audio"), "\(message)")
        #expect(message.contains("older-format recording") && message.contains(abbreviatedDisplayPath(outDir.path)))
        #expect(!message.contains("board"), "the folder, not the meeting")
        #expect(FileManager.default.fileExists(atPath: sentinel.systemAudioPath), "kept")
    }
}

/// 39: a leftover folder under `/Volumes/<name>` after an unplug is a ghost, not the drive.
@Suite struct FolderReachabilityTests {
    private let day = URL(fileURLWithPath: "/Volumes/Ext/Recordings/2026-09-24")

    @Test func aGhostMountPointIsUnreachable() {
        let ghost = RecordingCoordinator.FolderProbe(exists: { _ in true }, isWritable: { _ in true }, isVolumeRoot: { _ in false })
        #expect(!RecordingCoordinator.folderReachable(day, probe: ghost))
    }

    @Test func aMountedVolumeIsReachable() {
        let mounted = RecordingCoordinator.FolderProbe(exists: { _ in true }, isWritable: { _ in true }, isVolumeRoot: { $0.path == "/Volumes/Ext" })
        #expect(RecordingCoordinator.folderReachable(day, probe: mounted))
    }

    @Test func anUnmountedVolumeIsUnreachable() {
        let unmounted = RecordingCoordinator.FolderProbe(exists: { ["/", "/Volumes"].contains($0.path) }, isWritable: { _ in true }, isVolumeRoot: { _ in false })
        #expect(!RecordingCoordinator.folderReachable(day, probe: unmounted))
    }

    @Test func aFolderNotOnAnExternalVolumeHasNoMountCheck() {
        let noVolumes = RecordingCoordinator.FolderProbe(exists: { _ in true }, isWritable: { _ in true }, isVolumeRoot: { _ in false })
        #expect(RecordingCoordinator.folderReachable(URL(fileURLWithPath: "/Users/x/Documents/Recordings/day"), probe: noVolumes))
    }
}

// MARK: - L follow-ups: teardown on every end path, quit is not a crash

@MainActor
@Suite struct RecordingCoordinatorEndPathTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
    }

    /// 28: a crash whose recovery file is missing still ends the recording properly — the live pipeline
    /// is salvaged and torn down (no rotation timer left running), and the user is told what was kept.
    @Test func aCrashWithoutTheSentinelTearsTheLivePipelineDown() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let rotator = try #require(h.runner.chunkRotator)
        RecordingSentinel.delete(directory: h.tmp)   // e.g. deleted mid-recording
        await h.coordinator.handleXPCCrash()
        #expect(h.appState.isIdle && h.client.startCalls.count == 1)
        #expect(rotator.activeTimerForTesting == nil, "the rotation timer stopped")
        #expect(h.runner.chunkRotator == nil && h.runner.chunkProcessor == nil, "the pipeline torn down")
        #expect(h.criticals.value.map(\.title) == ["Recording Failed"])
    }

    /// 29: a live pipeline, a crash reported during a failed stop, and exactly one ingest of the chunk in
    /// progress: the stop path owns it all, no restart.
    @Test func aCrashDuringAFailedStopIngestsTheOrphanOnce() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let rotator = try #require(h.runner.chunkRotator)
        let outDir = try #require(h.client.startCalls.first).outputDirectory
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try Harness.headerOnlyWAV().write(to: outDir.appendingPathComponent(rotator.currentBaseName + ".wav"))
        h.client.stopError = FakeCaptureError()
        h.client.onStop = { await h.coordinator.handleXPCCrash() }
        await h.coordinator.stopRecording()
        #expect(h.client.startCalls.count == 1, "no restart")
        let critical = try #require(h.criticals.value.first)
        #expect(h.criticals.value.count == 1 && critical.body.contains("1 chunk"), "\(critical.body)")
    }

    /// 42: a deliberate quit while the transcript is being finished marks the recovery file, so the next
    /// launch does not call it a crash.
    @Test func aQuitDuringFinalizeMarksTheSentinel() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let call = try #require(h.client.startCalls.first)
        try FileManager.default.createDirectory(at: call.outputDirectory, withIntermediateDirectories: true)
        let sys = call.outputDirectory.appendingPathComponent(call.baseName + ".wav")
        try Harness.headerOnlyWAV().write(to: sys)
        h.client.stopResult = AudioPaths(systemAudio: sys, micAudio: call.outputDirectory.appendingPathComponent(call.baseName + "_mic.wav"))
        h.runner.finalizeDelayForTesting = .seconds(2)
        let coordinator = h.coordinator
        let stopping = Task { await coordinator.stopRecording() }
        await Harness.until { h.appState.isTranscribing }
        #expect(await h.coordinator.prepareForQuit(confirm: { Issue.record("no question while finishing"); return true }))
        #expect(RecordingSentinel.read(directory: h.tmp)?.quitDuringFinalize == true)
        stopping.cancel()
    }

    /// 42: the next launch words it as a quit, never a crash.
    @Test func aRelaunchAfterAQuitDuringFinalizeSaysSo() async throws {
        let h = try Harness()
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID()
        s.stopping = true; s.quitDuringFinalize = true
        try RecordingSentinel.write(s, directory: h.tmp)
        let outDir = URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent()
        try SessionState.write(SessionState(
            sessionId: "sess", meetingStart: Date(), engine: h.config.config.engine.rawValue, chunkDurationMinutes: 10,
            chunks: [ProcessedChunk(index: 0, startTime: Date(), audioPath: outDir.appendingPathComponent("sess-0.m4a").path,
                                    segments: [.init(start: 0, end: 1, text: "hello", speaker: "Speaker 1", source: "remote", qualityScore: nil)],
                                    speakerDatabase: [:])]
        ), directory: outDir)
        await h.coordinator.recoverAtLaunch()
        let message = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(message == "Parley was quit while finishing the transcript; it recovered 1 chunk to sess.json.", "\(message)")
    }
}

// MARK: - L follow-ups: Flow A keeps its pipeline, the evidence is adopted first, the crash time

@MainActor
@Suite struct RecordingCoordinatorReattachTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
    }

    private func freshSentinel(_ h: Harness, alive: TimeInterval = 20) throws -> RecordingSentinel {
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-alive); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        return s
    }

    private func dir(_ s: RecordingSentinel) -> URL { URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent() }

    /// 30: a recording re-attached after an app crash (the helper kept capturing) keeps its chunk pipeline:
    /// the rotator names the helper's live file, a rotation hands it over, and a low disk still alarms.
    @Test func aReattachRebuildsThePipelineOnTheHelpersLiveFile() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try freshSentinel(h)
        try RecoveryFixtures.writeSessionJSON(dir: dir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        let live = dir(s).appendingPathComponent("sess-1.wav")
        try Harness.headerOnlyWAV().write(to: live)   // the helper's live file (chunk 0 is done)
        let began = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 300).rounded(.down))
        try FileManager.default.setAttributes([.creationDate: began], ofItemAtPath: live.path)
        h.client.isCapturingResult = true
        await h.coordinator.recoverAtLaunch()
        #expect(h.appState.isRecording && h.client.startCalls.isEmpty, "re-attached, not restarted")
        let rotator = try #require(h.runner.chunkRotator)
        #expect(rotator.currentBaseName == "sess-1")
        #expect(abs(rotator.currentChunkInfo.startTime.timeIntervalSince(began)) < 1, "the live chunk began before this process")
        await rotator.rotateForTesting()
        #expect(h.client.rotateCalls == 1 && rotator.currentChunkInfo.index == 2, "the live file handed over")
        h.freeBytes.value = 1_000   // below one chunk
        await rotator.rotateForTesting()
        #expect(h.appState.activeAlarms[.diskLow] != nil)
    }

    /// 30: a chunk the crash cut short (sealed, never processed) goes through the live processor; the
    /// helper's live file is left to its rotation.
    @Test func aReattachIngestsTheOrphanButNotTheLiveFile() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try freshSentinel(h)
        try RecoveryFixtures.writeSessionJSON(dir: dir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        try Harness.headerOnlyWAV().write(to: dir(s).appendingPathComponent("sess-1.wav"))   // sealed, unprocessed
        try Harness.headerOnlyWAV().write(to: dir(s).appendingPathComponent("sess-2.wav"))   // live
        h.client.isCapturingResult = true
        await h.coordinator.recoverAtLaunch()
        #expect(h.runner.chunkRotator?.currentBaseName == "sess-2")
        let processor = try #require(h.runner.chunkProcessor)
        await processor.awaitAllProcessed()
        #expect(await processor.getSessionState().chunks.map(\.index).sorted() == [0, 1])
    }

    /// 43: the relaunch adopts the session with the capture client BEFORE anything can reset it, so the
    /// helper's sealed `captureStop` of the crashed app's session is drained into it, not dropped.
    @Test func aResumeAdoptsTheSessionBeforeTheStart() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try freshSentinel(h)
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.sessionCalls == ["adopt:sess", "start:sess"])
    }

    @Test func aReattachAdoptsTheSession() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try freshSentinel(h)
        h.client.isCapturingResult = true
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.sessionCalls == ["adopt:sess"])
    }

    /// 37: the newest orphan's last write IS when capture stopped. `lastAliveAt` is only the fallback: an
    /// in-process recovery's alive refreshes would otherwise overstate it.
    @Test func theCrashTimePrefersTheOrphanOverANewerLastAlive() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try freshSentinel(h, alive: 10)
        let wav = dir(s).appendingPathComponent("sess-0.wav")
        try Harness.headerOnlyWAV().write(to: wav)
        let sealed = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 40).rounded(.down))
        try FileManager.default.setAttributes([.modificationDate: sealed], ofItemAtPath: wav.path)
        await h.coordinator.recoverAtLaunch()
        let gap = try #require(await h.runner.chunkProcessor?.getSessionState().gaps.first)
        #expect(abs(gap.start.timeIntervalSince(sealed)) < 1)
    }

    /// 37: no liveness is vouched for while the helper is dead and a recovery runs.
    @Test func theAliveTimerPausesDuringARecovery() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        h.coordinator.aliveRefreshInterval = .milliseconds(20)
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.coordinator.recoveryInFlight = true
        var written = try #require(RecordingSentinel.read(directory: h.tmp))
        let stale = Date(timeIntervalSince1970: 1_000)
        written.lastAliveAt = stale
        try RecordingSentinel.write(written, directory: h.tmp)
        try await Task.sleep(for: .milliseconds(120))
        #expect(RecordingSentinel.read(directory: h.tmp)?.lastAliveAt == stale)
        h.coordinator.recoveryInFlight = false
    }
}
