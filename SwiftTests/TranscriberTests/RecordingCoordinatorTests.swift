import Testing
import Foundation
@testable import TranscriberCore

/// Tests for the recording-lifecycle + crash-recovery orchestration extracted from MenuView
/// (#139 audit finding 3 / PR-6). Uses a fake capture client — no real audio, no XPC — and a
/// per-test sentinel directory so nothing touches the real app-support path.
@MainActor
final class FakeCaptureClient: RecordingCaptureClient {
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
        sessionCalls.append("start:\(sessionId)@\(outputDirectory.standardized.path)")
        // As production's start: its drain first, then `beginCapture` — a NEW session resets what was recorded (L
        // review 146).
        drains.append("start:\(sessionId)")
        bind(sessionId, outputDirectory)
        realEvidence?.beginCapture(sessionId: sessionId, directory: outputDirectory)
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
    /// Bind, attribute, adopt, finalize (build), commit — in order (L review 97, 98, 121).
    var evidenceOrder: [String] = []
    /// Every drain of the helper's ring, where production drains it (L review 198): a start's, an adopt's and a build's —
    /// each unless told not to — as "<step>:<session id>". The attribution's drain is `evidenceOrder`'s "attribute:".
    var drains: [String] = []
    /// The session the evidence is bound to. Binding a NEW one resets what was recorded, as production's
    /// `beginCapture` does (L reviews 121, 146).
    var bound: (id: String, directory: String)?
    private func bind(_ sessionId: String, _ directory: URL) {
        let key = (sessionId, SessionEvidence.key(directory))
        if bound.map({ $0.id != key.0 || $0.directory != key.1 }) ?? true { recordedEvents = [] }
        bound = key
    }
    private func isBound(_ sessionId: String, _ directory: URL) -> Bool {
        bound.map { $0.id == sessionId && $0.directory == SessionEvidence.key(directory) } ?? false
    }
    /// When set, the evidence calls also go to this REAL `SessionEvidence` (L review 139): a coordinator test sees the
    /// record files production would write.
    var realEvidence: SessionEvidence?
    func bindSession(sessionId: String, directory: URL) {
        evidenceOrder.append("bind:\(sessionId)")
        bind(sessionId, directory)
        realEvidence?.beginCapture(sessionId: sessionId, directory: directory)
    }
    /// Awaited inside adoptSession(): lets a test act while a re-attach adopts (L review 72).
    var onAdopt: (() async -> Void)?
    func adoptSession(sessionId: String, directory: URL, drainHelper: Bool) async {
        sessionCalls.append("adopt:\(sessionId)@\(directory.standardized.path)")
        evidenceOrder.append(drainHelper ? "adopt:\(sessionId)" : "adopt-undrained:\(sessionId)")
        if drainHelper { drains.append("adopt:\(sessionId)") }
        bind(sessionId, directory)
        realEvidence?.beginCapture(sessionId: sessionId, directory: directory)
        await onAdopt?()
    }
    var commitCalls: [String] = []
    /// Runs inside the commit: (session id, folder).
    var onCommit: ((String, URL) -> Void)?
    func commitSessionDiagnostics(sessionId: String, directory: URL) {
        commitCalls.append(sessionId)
        evidenceOrder.append("commit:\(sessionId)")
        onCommit?(sessionId, directory)
        realEvidence?.commit(sessionId: sessionId, directory: directory)
    }
    /// Whether the attribution's drain answered (L review 142).
    var attributionAnswers = true
    func attributeHelperDrain(toOneOf sessions: [(sessionId: String, directory: URL)]) async -> Bool {
        evidenceOrder.append("attribute:" + sessions.map(\.sessionId).joined(separator: ","))
        return attributionAnswers
    }
    func attributeRefusedStartDrain(toOneOf sessions: [(sessionId: String, directory: URL)]) async {
        evidenceOrder.append("attribute-refused:" + sessions.map(\.sessionId).joined(separator: ","))
    }
    var flushCalls = 0
    /// Awaited inside the flush: lets a test hang it.
    var onFlush: (() async -> Void)?
    func flushEvidence() async {
        flushCalls += 1
        await onFlush?()
    }
    /// Sessions whose evidence was dropped: a start that never became a recording (L11 review 68).
    var discardedSessions: [String] = []
    func discardSessionEvidence(sessionId: String, directory: URL) {
        discardedSessions.append(sessionId)
        guard isBound(sessionId, directory) else { return }
        bound = nil   // as production's `discard`: unbound, its ring dropped (L review 146)
        discardedEvents += recordedEvents
        recordedEvents = []
    }
    /// What `discardSessionEvidence` dropped with its session.
    var discardedEvents: [(kind: CaptureEventKind, severity: CaptureEvent.Severity, detail: [String: String])] = []

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
        realEvidence?.record(CaptureEvent(timestamp: Date(), origin: .app, kind: kind, severity: severity, detail: detail))
    }

    /// With no `stopResult`: answer "No capture in progress" when not capturing, as the real helper does — so a
    /// bounded helper stop "lets go" by default, and a test that needs a stop that merely FAILS sets this false (or a
    /// `stopError`). A test that needs the stop to hand back files sets `stopResult` (L review 135: the default,
    /// documented where every test reads it).
    var stopsLikeTheHelper = true
    /// Whether the task running `stop()` was already cancelled (L2/L4 fix round 2, item 3).
    var stopSawCancellation: Bool?
    func stop() async throws -> AudioPaths {
        stopCalls += 1
        stopSawCancellation = Task.isCancelled
        await onStop?()
        if let stopError { throw stopError }
        guard let stopResult else {
            // As the real helper answers when nothing is capturing (its stop then "lets go").
            if (captureStateResult ?? (isCapturingResult ? .capturing : .notCapturing)) == .notCapturing, stopsLikeTheHelper {
                throw NoCaptureError()
            }
            throw CocoaError(.fileNoSuchFile)
        }
        return stopResult
    }

    /// Awaited inside the record's build, before the transcript is written: a test reads the session there.
    var onFinalizeDiagnostics: (() async -> Void)?
    /// What each build took from the ring, in order: (session id, the events recorded for it). The ring itself is
    /// reset by the build, as production's is (L review 146).
    var builtRecords: [(sessionId: String, events: [(kind: CaptureEventKind, severity: CaptureEvent.Severity, detail: [String: String])])] = []
    /// Every event recorded, whatever build took it.
    var everyRecordedEvent: [(kind: CaptureEventKind, severity: CaptureEvent.Severity, detail: [String: String])] {
        builtRecords.flatMap(\.events) + discardedEvents + recordedEvents
    }
    func finalizeSessionDiagnostics(
        sessionId: String, engine: String, recordingDirectory: URL, drainHelper: Bool
    ) async -> CaptureProvenance {
        await onFinalizeDiagnostics?()
        finalizeCalls.append((sessionId, engine, recordingDirectory))
        evidenceOrder.append("finalize:\(sessionId)")
        if drainHelper { drains.append("finalize:\(sessionId)") }
        // As production's build: the ring is this session's when bound to it or nothing is bound — then it is taken,
        // and reset; the binding ends (L review 146).
        let ownsRing = bound == nil || isBound(sessionId, recordingDirectory)
        builtRecords.append((sessionId, ownsRing ? recordedEvents : []))
        if ownsRing { recordedEvents = [] }
        if isBound(sessionId, recordingDirectory) { bound = nil }
        if let realEvidence { _ = await realEvidence.finalize(sessionId: sessionId, directory: recordingDirectory) }
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
    /// The sealed chunk's paths a rotation answers with, as the real helper does (default: the new name's).
    var rotateReply: ((String) -> (systemPath: String, micPath: String))?
    func rotateChunk(outputDirectory: String, newBaseName: String) async throws
        -> (systemPath: String, micPath: String) {
        rotateCalls += 1
        await onRotate?()
        if let rotateError { throw rotateError }
        if let rotateReply { return rotateReply(newBaseName) }
        return (outputDirectory + "/" + newBaseName + ".wav",
                outputDirectory + "/" + newBaseName + "_mic.wav")
    }
}

struct FakeCaptureError: Error, LocalizedError {
    var errorDescription: String? { "fake capture failure" }
}

/// The helper's reply to a rotate when it is not capturing: the capture is dead (§8.7).
struct NoCaptureError: Error, LocalizedError {
    var errorDescription: String? { CaptureReplies.noCaptureInProgress }
}

/// The helper's reply to a rotate while it is stopping (council B-I3, stream H2): not a dead capture.
struct RefusedStoppingError: Error, LocalizedError {
    var errorDescription: String? { CaptureReplies.refusedStopping }
}

/// Any other helper reply, by its wire text (a `CaptureReplies` constant).
struct HelperReplyError: Error, LocalizedError {
    let reply: String
    var errorDescription: String? { reply }
}

@MainActor
struct Harness {
    let tmp: URL
    let appState = AppState()
    let client = FakeCaptureClient()
    let runner = TranscriptionRunner()
    let config: ConfigManager
    let coordinator: RecordingCoordinator
    let notified: Box<[(title: String, body: String)]> = Box([])
    let criticals: Box<[(title: String, body: String)]> = Box([])
    let presented: Box<[URL]> = Box([])
    /// Runs as each transcript is presented, after it is recorded in `presented` — as the app's rename panel would.
    let onPresent: Box<((URL) -> Void)?> = Box(nil)
    /// The engine a launch salvage transcribes with, and an error its preparation throws instead (L review 178).
    let engine: Box<any TranscriptionEngine> = Box(FakeEngine())
    let engineError: Box<Error?> = Box(nil)
    /// The diarizer a launch salvage diarizes with (L review 232).
    let diarizer: Box<any DiarizationProvider> = Box(FakeDiarizer())
    let repairRequests: Box<Int> = Box(0)
    /// What the repair path answers: true = its window presented (L round 4, item 4).
    let repairPresents: Box<Bool> = Box(true)
    /// The free space every disk check reads (L8): plenty unless a test says otherwise, so no test
    /// depends on the machine's real disk.
    let freeBytes: Box<Int?> = Box(Int.max)
    /// Runs inside every disk read, on whatever thread reads (L follow-up 33, L11 review 70).
    let diskReadHook: Box<(@Sendable () -> Void)?> = Box(nil)
    let recordingMic: RecordingMicrophone

    /// `@unchecked Sendable`: tests hand it to `@Sendable` seams that run OFF the main actor (the disk and folder
    /// reads, the rotator's reply); a test reads it only once the work that writes it has finished.
    final class Box<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }

    /// `launchRecoveryPending`: the recovery gate starts held until `recoverAtLaunch` runs, as in the app (L review
    /// 131). Off by default: most tests drive a retry without a launch.
    /// `tmp`: another harness's folder — a relaunch of the same app, as a new process sees it (L review 236).
    init(recordingMic: RecordingMicrophone = RecordingMicrophone(), launchRecoveryPending: Bool = false, tmp: URL? = nil) throws {
        self.recordingMic = recordingMic
        self.tmp = tmp ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.tmp, withIntermediateDirectories: true)
        config = ConfigManager(configDir: self.tmp)  // empty dir -> Config.default
        let notified = notified
        let criticals = criticals
        let presented = presented, onPresent = onPresent
        let repairRequests = repairRequests
        let repairPresents = repairPresents
        let freeBytes = freeBytes, diskReadHook = diskReadHook
        let engine = engine, engineError = engineError, diarizer = diarizer
        coordinator = RecordingCoordinator(
            appState: appState,
            captureClient: client,
            transcriptionRunner: runner,
            configManager: config,
            sentinelDirectory: self.tmp,
            notify: { notified.value.append(($0, $1)) },
            notifyCritical: { criticals.value.append(($0, $1)) },
            presentTranscript: { url, _ in presented.value.append(url); onPresent.value?(url) },
            onSystemAudioPermissionDenied: { repairRequests.value += 1; return repairPresents.value },
            engineFactory: { _ in
                if let error = engineError.value { throw error }
                return (engine.value, diarizer.value)
            },
            recordingMicrophone: recordingMic,
            freeBytesProvider: { _ in diskReadHook.value?(); return freeBytes.value },
            launchRecoveryPending: launchRecoveryPending
        )
        coordinator.displayIsAwake = { true }   // never the test machine's own display
        // Its own folder-read queue: a test that hangs a read never delays the next test's (the app shares one).
        coordinator.folderReads = FolderReads(label: "rc-tests-\(UUID().uuidString)")
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
        h.client.bindSession(sessionId: "sess", directory: h.tmp.appendingPathComponent("out"))   // its start bound it
        h.appState.phase = .recording(since: Date())
        h.client.statusSnapshot = notCapturing("1000-0", 1)
        await h.coordinator.pollHelperStatus()
        #expect(h.client.startCalls.isEmpty, "one poll is not enough")
        h.client.statusSnapshot = notCapturing("1000-0", 2)
        await h.coordinator.pollHelperStatus()
        // Dispatched outside the poll task (fix round 2, item 3): let it run (its restart plans off the main actor).
        await Harness.until { !h.client.startCalls.isEmpty }
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
            await Harness.until { h.coordinator.crashBeforeRecording }   // noted, the phase still .idle
        }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        // A deadline, never a count of yields: the restart's reads hop through dispatch queues (it failed 3 runs in 6 alone at 1425b37).
        await Harness.until { client.startCalls.count >= 2 }
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
            await Harness.until { h.coordinator.crashBeforeRecording }
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
        h.client.stopsLikeTheHelper = false   // a stop that merely fails
        await h.coordinator.stopRecording()   // no sentinel, no session: nothing recorded
        let critical = try #require(h.criticals.value.first)
        #expect(critical.body == RecoveryMessages.stopFailed(
            after: SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0), error: CocoaError(.fileNoSuchFile).localizedDescription))
    }

    @Test func crashWithoutSentinelEscalatesCritically() async throws {
        let h = try Harness()

        h.appState.phase = .recording(since: Date())
        await h.coordinator.handleXPCCrash()

        // L review 87: no recovery file AND no pipeline — nothing was looked at, so nothing is claimed about
        // what was recorded; never "no recorded audio".
        let critical = try #require(h.appState.criticalError)
        #expect(critical.hasPrefix("Recording failed — its recovery file was missing"), "\(critical)")
        #expect(!critical.contains("no recorded audio") && !(h.criticals.value.first?.body.contains("no recorded audio") ?? true))
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
        // The restart is over — its recovery file written off the main actor (L review 217) — before the test ends it.
        while (h.client.startCalls.count < wiredStarts + 1 || h.coordinator.recoveryInFlight) && tries < 1000 {
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

        // As the relaunch reads it: the file keeps whole seconds, and the row's clock is formatted from that.
        let stored = try #require(RecordingSentinel.read(directory: h.tmp))
        await coordinator.recoverAtLaunch()   // helper not capturing → Flow B, chunked

        let json = outDir.appendingPathComponent("sess.json")
        #expect(h.presented.value == [json], "the recovered transcript goes through the normal completion path")
        #expect(h.appState.activeAlarms[.recordingStopped]?.message == RecoveryMessages.relaunchStopped(
            at: stored.startedAt, outcome: SalvageOutcome(kind: .transcriptWritten(json), chunkCount: 1)))
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

    /// Item 8, as L review 178 rules it: the engine cannot even be prepared — not the audio's failure. The chunk stays on
    /// disk, the session is kept pending (out of the slot) for when the engine is ready, and the row says so. With audio to
    /// recognise — its chunk 1 (L review 232: with none, no engine is needed).
    @Test func launchSalvageWithoutAnEngineKeepsTheSession() async throws {
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
        let orphan = outDir.appendingPathComponent("sess-1.wav")
        try RecoveryFixtures.writeFakeWav(at: orphan, seconds: 1)
        let stoppedAt = try #require(try FileManager.default.attributesOfItem(atPath: orphan.path)[.modificationDate] as? Date)
        await coordinator.salvageAtLaunch(sentinel: sentinel, outputDir: outDir)
        #expect(h.appState.activeAlarms[.recordingStopped]?.message == RecoveryMessages.waitingForEngine(
            at: stoppedAt, folder: abbreviatedDisplayPath(outDir.path), why: FakeCaptureError().localizedDescription))
        #expect(h.appState.isIdle && RecordingSentinel.read(directory: h.tmp) == nil)
        #expect(RecordingSentinel.readPending(directory: h.tmp).map(\.sessionKey) == [sentinel.sessionKey], "kept for the engine")
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
        var s = try writeSentinel(h, alive: 30)
        s.startedAt = Date().addingTimeInterval(-3600)   // the recording began an hour ago (L review 78)
        try RecordingSentinel.write(s, directory: h.tmp)
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
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
        // Real audio on disk, never transcribed (41d, L review 80): salvaged into a transcript, never discarded
        // with the stale sentinel.
        try RecoveryFixtures.writeFakeWav(at: outDir(s).appendingPathComponent("sess-0.wav"), seconds: 1)
        try RecoveryFixtures.writeFakeWav(at: outDir(s).appendingPathComponent("sess-0_mic.wav"), seconds: 1)
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.isEmpty && h.appState.activeAlarms[.recordingStopped] != nil)
        let transcript = outDir(s).appendingPathComponent("sess.json")
        #expect(h.presented.value == [transcript], "salvaged, not deleted")
        let text = try String(contentsOf: transcript, encoding: .utf8)
        #expect(text.contains("hello"), "the orphan's audio was transcribed (the fake engine says hello)")
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
            await coordinator.settleSentinelIOForTesting()   // the mark is queued off the main actor (L review 217)
            markedWhileRestarting.value = RecordingSentinel.read(directory: h.tmp)?.stopping
        }
        await h.coordinator.handleXPCCrash()
        #expect(markedWhileRestarting.value == true)
    }

    @Test func refreshSentinelLivenessRewritesLastAliveAt() async throws {
        let h = try Harness()
        _ = try writeSentinel(h, alive: 30)
        let now = Date(timeIntervalSince1970: 5_000)
        h.coordinator.refreshSentinelLiveness(now: now)
        await h.coordinator.settleSentinelIOForTesting()   // queued off the main actor (L review 217)
        #expect(RecordingSentinel.read(directory: h.tmp)?.lastAliveAt == now)
    }

    @Test func refreshNeverCreatesASentinel() async throws {
        let h = try Harness()
        h.coordinator.refreshSentinelLiveness()
        await h.coordinator.settleSentinelIOForTesting()
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
        await h.coordinator.settleSentinelIOForTesting()   // the liveness write is queued off the main actor (L review 217)
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

    /// L review 75: the relaunch reads the session's folder off the main actor, bounded. One that hangs is
    /// treated as unreachable — the session waits, never salvaged as "no recorded audio".
    @Test func aHungFolderAtRelaunchWaitsNeverSalvaged() async throws {
        let h = try Harness()
        let s = try writeSentinel(h, alive: 600)
        h.coordinator.folderReadDeadline = .milliseconds(100)
        let onMain = Harness.Box<Bool?>(nil)
        h.coordinator.folderProbe = .init(exists: { _ in onMain.value = Thread.isMainThread; Thread.sleep(forTimeInterval: 1); return true },
                                          isWritable: { _ in true }, isVolumeRoot: { _ in false })
        let began = ContinuousClock.now
        await h.coordinator.recoverAtLaunch()
        #expect(ContinuousClock.now - began < .seconds(1))
        #expect(onMain.value == false)
        #expect(RecordingSentinel.readPending(directory: h.tmp).map(\.sessionKey) == [s.sessionKey])
        #expect(h.presented.value.isEmpty && h.appState.activeAlarms[.recordingStopped] == nil)
        #expect(h.appState.activeAlarms[.recordingFolderUnavailable] != nil)
    }

    /// L review 75: … and the mount/wake retry reads the pending folders the same way.
    @Test func aHungFolderAtRetryIsSkipped() async throws {
        let h = try Harness()
        let locked = try writeUnreachableSentinel(h)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        await h.coordinator.recoverAtLaunch()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        h.coordinator.folderReadDeadline = .milliseconds(100)
        h.coordinator.folderProbe = .init(exists: { _ in Thread.sleep(forTimeInterval: 1); return true },
                                          isWritable: { _ in true }, isVolumeRoot: { _ in false })
        let began = ContinuousClock.now
        await h.coordinator.retryPendingSessions()
        #expect(ContinuousClock.now - began < .seconds(1))
        #expect(RecordingSentinel.readPending(directory: h.tmp).count == 1 && h.presented.value.isEmpty)
        #expect(h.appState.activeAlarms[.recordingFolderUnavailable] != nil)
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
        // A drive that is not mounted (a read-only parent is a permissions problem since L review 126).
        h.config.update { $0.recordingDirectory = "/Volumes/Absent-\(UUID().uuidString)/Recordings" }
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

    /// L review 74: a folder read that hangs (a dead network share) is the FOLDER's fault, said so within its
    /// own short bound — never "the audio system didn't respond".
    @Test func aHungFolderReadRefusesTheStartInFolderWords() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        h.coordinator.folderReadDeadline = .milliseconds(100)
        h.coordinator.folderProbe = .init(exists: { _ in Thread.sleep(forTimeInterval: 1); return true },
                                          isWritable: { _ in true }, isVolumeRoot: { _ in false })
        let began = ContinuousClock.now
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(ContinuousClock.now - began < .milliseconds(600))
        #expect(h.client.startCalls.isEmpty && !h.coordinator.isStartInFlight)
        let body = try #require(h.notified.value.last?.body)
        #expect(h.notified.value.last?.title == "Recording not started")
        // Not answering within its own bound — never "not reachable" (L review 210).
        #expect(body.hasPrefix("The recording folder isn’t answering — is its drive or network share still available?"), "\(body)")
        #expect(!body.contains("audio system"))
    }

    /// L review 79: a recording folder that is there but read-only is a permissions problem, said so.
    @Test func aReadOnlyRecordingFolderIsSaidToBeAPermissionsProblem() async throws {
        let h = try Harness()
        let folder = h.tmp.appendingPathComponent("rec")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        h.config.update { $0.recordingDirectory = folder.path }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(h.client.startCalls.isEmpty)
        #expect(h.appState.errorMessage?.hasPrefix("Parley can’t write to the recording folder — check its permissions") == true, "\(h.appState.errorMessage ?? "nil")")
    }

    /// L review 71: a recording folder reached through a link to an unplugged drive refuses the start.
    @Test func aStartThroughADanglingLinkIsRefused() async throws {
        let h = try Harness()
        let link = h.tmp.appendingPathComponent("Recordings")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Volumes/Absent-\(UUID().uuidString)/Recordings")
        h.config.update { $0.recordingDirectory = link.path }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(h.client.startCalls.isEmpty)
        #expect(h.appState.errorMessage?.contains("isn’t reachable") == true)
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
        await h.coordinator.awaitRotationDiskCheckForTesting()
        #expect(h.appState.activeAlarms[.diskLow] != nil)
        #expect(h.client.recordedEvents.contains { $0.kind == .diskLow && $0.severity == .warning && $0.detail["free_mb"] != nil })
        h.freeBytes.value = chunk + 1
        await h.runner.chunkRotator?.rotateForTesting()
        await h.coordinator.awaitRotationDiskCheckForTesting()
        #expect(h.appState.activeAlarms[.diskLow] != nil, "still low: under two chunks")
        h.freeBytes.value = 2 * chunk
        await h.runner.chunkRotator?.rotateForTesting()
        await h.coordinator.awaitRotationDiskCheckForTesting()
        #expect(h.appState.activeAlarms[.diskLow] == nil)
    }

    /// L11 review 70: the rotation's free-space read runs off the main actor — a hung network volume never
    /// stalls the UI — and is bounded: past its deadline the check is skipped for this rotation (logged),
    /// never an alarm from a read that did not answer.
    @Test func theRotationDiskReadIsOffTheMainActorAndBounded() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let onMain = Harness.Box<Bool?>(nil)
        h.diskReadHook.value = { onMain.value = Thread.isMainThread }
        await h.runner.chunkRotator?.rotateForTesting()
        await h.coordinator.awaitRotationDiskCheckForTesting()
        #expect(onMain.value == false)

        h.coordinator.rotationDiskReadDeadline = .milliseconds(100)
        h.diskReadHook.value = { Thread.sleep(forTimeInterval: 1) }
        h.freeBytes.value = 1_000   // it WOULD be low — but the read does not answer in time
        let began = ContinuousClock.now
        await h.runner.chunkRotator?.rotateForTesting()
        await h.coordinator.awaitRotationDiskCheckForTesting()
        #expect(ContinuousClock.now - began < .milliseconds(600), "bounded at 100 ms, never the 1 s read")
        #expect(h.appState.activeAlarms[.diskLow] == nil, "skipped for this rotation")
        #expect(h.appState.isRecording)
    }

    /// L9 review 46: a rotation that timed out and then completed in the helper is reconciled at Stop: the
    /// sealed chunk is emitted from its own files and the stop's last chunk is the helper's, not relabelled.
    @Test func aRotationCompletedLateIsReconciledAtStop() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let rotator = try #require(h.runner.chunkRotator)
        let outDir = try #require(h.client.startCalls.first).outputDirectory
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let next = String(rotator.currentBaseName.dropLast(2)) + "-1"
        h.client.rotateError = CaptureCallTimeout(call: "rotateChunk", seconds: 10)
        await rotator.rotateForTesting()
        for suffix in [".wav", "_mic.wav"] {   // the helper completed it anyway: it is writing chunk 1
            try Harness.headerOnlyWAV().write(to: outDir.appendingPathComponent(next + suffix))
        }
        h.client.stopResult = AudioPaths(systemAudio: outDir.appendingPathComponent(next + ".wav"),
                                         micAudio: outDir.appendingPathComponent(next + "_mic.wav"))
        let runner = h.runner
        let chunks = Harness.Box<[ProcessedChunk]>([])
        h.client.onFinalizeDiagnostics = { chunks.value = await runner.chunkProcessor?.getSessionState().chunks ?? [] }
        await h.coordinator.stopRecording()
        #expect(rotator.currentChunkInfo.index == 1, "the stop's last chunk is the helper's chunk 1")
        #expect(h.presented.value.count == 1)
        // L review 118: which files each chunk came from — chunk i from its own `-i` audio.
        #expect(chunks.value.map(\.index).sorted() == [0, 1])
        for chunk in chunks.value {
            #expect(URL(fileURLWithPath: chunk.audioPath).deletingPathExtension().lastPathComponent.hasSuffix("-\(chunk.index)"), "\(chunk.audioPath)")
        }
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
        await Harness.until { h.client.rotateCalls == 1 }   // it looks at its folder off the main actor first (L review 158)
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

    /// L review 91 (item 48): the one place that reads the helper's replies matches every one the app acts on
    /// exactly, by its `CaptureReplies` constant — never by a guess at its wording.
    @Test func everyHelperReplyIsMatchedByItsConstant() {
        #expect(RecordingCoordinator.helperReply(CaptureReplies.noCaptureInProgress) == .notCapturing)
        #expect(RecordingCoordinator.helperReply(CaptureReplies.refusedStopping) == .stopping)
        #expect(RecordingCoordinator.helperReply(CaptureReplies.rotationTimedOut) == .rotationTimedOut)
        #expect(RecordingCoordinator.helperReply(CaptureReplies.alreadyInProgress) == .alreadyCapturing)
        #expect(RecordingCoordinator.helperReply(CaptureReplies.cancelledWhileStarting) == .startCancelled)
        #expect(RecordingCoordinator.helperReply(CaptureReplies.startCancelled) == .startCancelled)
        #expect(RecordingCoordinator.helperReply(CaptureReplies.startTimedOut) == .startTimedOut)
        #expect(RecordingCoordinator.helperReply("refused: stopping") == .other, "the helper's real wording only")
        #expect(RecordingCoordinator.helperReply("XPC connection failed: boom") == .other)
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
        #expect(h.client.everyRecordedEvent.contains { $0.kind == .xpcTimeout })

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
        #expect(RecordingSentinel.read(directory: h.tmp) == nil && h.client.everyRecordedEvent.contains { $0.kind == .xpcTimeout })
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
        // Held (L review 81): pending, marked stopping, the mic kept marked.
        #expect(RecordingSentinel.readPending(directory: h.tmp).first?.stopping == true && h.recordingMic.current == .some("mic-1"))
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
        #expect(RecordingSentinel.readPending(directory: h.tmp).first?.stopping == true, "held (L review 81): never resumed, salvaged once the helper lets go")
        #expect(RecordingSentinel.read(directory: h.tmp) == nil, "out of the slot a next Start writes")
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
        // A deadline, never a fixed number of yields (L review 165): the wake's rotation looks at the folder off the main
        // actor first (measured in round G: 1 run in 6 missed 50 yields).
        await Harness.until { h.client.powerEvents.count == 2 && h.client.rotateCalls == 1 }
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

    /// §8.10: the Mac does not idle-sleep from a recording's start (a lid close is the user's call: recorded as a
    /// gap, not fought) until the app is idle again, whatever ended it (L10 review 59; renamed, L review 110).
    @Test func idleSleepIsPreventedFromTheStartUntilTheAppIsIdle() async throws {
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

    /// Writes header-only WAVs for the recording's first chunk and makes the fake's stop return them.
    private func stopReturnsTheFirstChunk(_ h: Harness) throws {
        let call = try #require(h.client.startCalls.first)
        try FileManager.default.createDirectory(at: call.outputDirectory, withIntermediateDirectories: true)
        let sys = call.outputDirectory.appendingPathComponent(call.baseName + ".wav")
        let mic = call.outputDirectory.appendingPathComponent(call.baseName + "_mic.wav")
        try Harness.headerOnlyWAV().write(to: sys); try Harness.headerOnlyWAV().write(to: mic)
        h.client.stopResult = AudioPaths(systemAudio: sys, micAudio: mic)
    }

    /// L10 review 53: logout, shutdown, restart or a quit from outside Parley — the process ends NOW. Within a
    /// tight bound the helper is stopped (it seals its files), the sentinel stays marked stopping (and quit),
    /// and the long finalize is skipped: the next launch salvages it.
    @Test func aTerminationStopsTheHelperAndLeavesTheFinalizeToTheNextLaunch() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.prepareForTermination(bound: .seconds(1))
        #expect(h.client.stopCalls == 0, "idle: nothing to stop")
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try stopReturnsTheFirstChunk(h)
        #expect(h.coordinator.hasWorkInFlight)
        await h.coordinator.prepareForTermination(bound: .seconds(1))
        #expect(h.client.stopCalls == 1, "the helper sealed its files")
        let sentinel = try #require(RecordingSentinel.read(directory: h.tmp))
        #expect(sentinel.stopping && sentinel.quitDuringFinalize, "the next launch salvages it, worded as a quit")
        #expect(h.client.finalizeCalls.isEmpty && h.presented.value.isEmpty, "the long finalize is skipped")
    }

    /// … and a helper that hangs cannot hold the logout: the preparation ends within its bound.
    @Test func aTerminationWhoseHelperHangsEndsWithinItsBound() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.client.onStop = { try? await Task.sleep(for: .seconds(3)) }
        let began = ContinuousClock.now
        await h.coordinator.prepareForTermination(bound: .milliseconds(200))
        #expect(ContinuousClock.now - began < .milliseconds(600))
        let sentinel = try #require(RecordingSentinel.read(directory: h.tmp))
        #expect(sentinel.quitDuringFinalize && sentinel.stopping, "salvage-only, worded as a quit (L review 109)")
        #expect(h.client.droppedConnections == 1, "the hung helper's connection is dropped: its invalidation handler stops it")
    }

    /// L review 109 / 111 (M7): a termination during the user's Stop waits for the helper's answer only — and when
    /// that does not come within the bound, drops the connection so the helper stops on its invalidation.
    @Test func aTerminationDuringAHungStopDropsTheConnectionAtItsBound() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.client.onStop = { try? await Task.sleep(for: .seconds(2)) }
        let coordinator = h.coordinator
        let stopping = Task { await coordinator.stopRecording() }
        await Harness.until { h.client.stopCalls == 1 }
        let began = ContinuousClock.now
        await h.coordinator.prepareForTermination(bound: .milliseconds(200))
        #expect(ContinuousClock.now - began < .milliseconds(600))
        #expect(h.client.stopCalls == 1, "the Stop in flight asks the helper — never a second stop")
        #expect(h.client.droppedConnections == 1, "dropped at the bound, once")
        #expect(RecordingSentinel.read(directory: h.tmp).map { $0.stopping && $0.quitDuringFinalize } == true)
        await stopping.value
    }

    /// L review 109: a termination during a crash restart keeps the user's stop across the restart's sentinel
    /// rewrite (a pin of the `recoveryInFlight` branch).
    @Test func aTerminationDuringACrashRestartKeepsTheStopMark() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let released = Harness.Box(false)
        h.client.onStartAsync = { while !released.value { await Task.yield() } }
        let coordinator = h.coordinator
        let recovering = Task { await coordinator.handleXPCCrash() }
        await Harness.until { h.client.startCalls.count == 2 }
        await h.coordinator.prepareForTermination(bound: .milliseconds(200))
        #expect(h.coordinator.stopRequestedDuringRecovery, "the restart will honour the stop")
        #expect(RecordingSentinel.read(directory: h.tmp).map { $0.stopping && $0.quitDuringFinalize } == true)
        released.value = true
        await recovering.value
    }

    /// L5 review, kept for termination: a start in flight is waited for (within the bound), then stopped.
    @Test func aTerminationDuringAStartWaitsForItAndStops() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        let released = Harness.Box(false)
        h.client.onStartAsync = { while !released.value { await Task.yield() } }
        h.client.stopResult = AudioPaths(systemAudio: h.tmp.appendingPathComponent("a.wav"), micAudio: h.tmp.appendingPathComponent("a_mic.wav"))
        let coordinator = h.coordinator
        let starting = Task { await coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil) }
        for _ in 0..<20 { await Task.yield() }
        #expect(h.coordinator.hasWorkInFlight, "a start in flight is busy")
        let terminating = Task { await coordinator.prepareForTermination(bound: .seconds(2)) }
        for _ in 0..<20 { await Task.yield() }
        #expect(h.client.stopCalls == 0)
        released.value = true
        let releasedAt = ContinuousClock.now
        await starting.value
        await terminating.value
        #expect(h.client.stopCalls == 1)
        // CI-safe (L review 173): well under the bound a poll would have to wait out, never a tight 100 ms.
        #expect(ContinuousClock.now - releasedAt < .milliseconds(500), "awaited, not polled (L review 109)")
    }

    /// A termination while the transcript is being finished: nothing left to stop — the sentinel is marked,
    /// and the preparation returns at once.
    @Test func aTerminationDuringAFinalizeMarksTheSentinelAtOnce() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try stopReturnsTheFirstChunk(h)
        h.runner.finalizeDelayForTesting = .milliseconds(600)
        let coordinator = h.coordinator
        let stopping = Task { await coordinator.stopRecording() }
        await Harness.until { h.appState.isTranscribing }
        #expect(h.coordinator.hasWorkInFlight, "a finalize is busy")
        let began = ContinuousClock.now
        await h.coordinator.prepareForTermination(bound: .seconds(5))
        #expect(ContinuousClock.now - began < .milliseconds(500))
        #expect(RecordingSentinel.read(directory: h.tmp)?.quitDuringFinalize == true && h.client.stopCalls == 1)
        await stopping.value   // awaited, never cancelled into the next test
    }

    /// L review 85: the process can end in the same turn a logout is announced or a termination answered —
    /// the marks are SYNCHRONOUS, never inside a Task. The terminate delegate's mark makes a live recording's
    /// sentinel salvage-only and worded as a quit before any await.
    @Test func theTerminationMarkIsSynchronous() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.coordinator.markForTermination()   // no await: this is all the process may get
        let sentinel = try #require(RecordingSentinel.read(directory: h.tmp))
        #expect(sentinel.stopping && sentinel.quitDuringFinalize)
    }

    /// L review 85: `willPowerOff` marks a transcript being finished as a quit, synchronously — and leaves a live
    /// recording alone (a logout can still be cancelled).
    @Test func thePowerOffMarkIsSynchronousAndSparesALiveRecording() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.coordinator.markExitDuringFinalize()
        #expect(RecordingSentinel.read(directory: h.tmp)?.quitDuringFinalize == false, "a live recording is not a finishing one")
        try stopReturnsTheFirstChunk(h)
        h.runner.finalizeDelayForTesting = .milliseconds(300)
        let coordinator = h.coordinator
        let stopping = Task { await coordinator.stopRecording() }
        await Harness.until { h.appState.isTranscribing }
        h.coordinator.markExitDuringFinalize()   // no await
        #expect(RecordingSentinel.read(directory: h.tmp)?.quitDuringFinalize == true)
        await stopping.value
    }

    /// L10 review 54: a sleep and a wake while a Stop is in flight. The helper still gets its "sleep"/"wake"
    /// pair and the wake is recorded — but nothing restarts the recording that is ending: no rotation into
    /// the stopping helper, no rotation timer (it would wake the idle app forever), no poll, no banner.
    @Test func aSleepAndWakeDuringAStopKeepThePairingButRestartNothing() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        h.coordinator.preflight = { _ in (false, false) }   // no lid-closed banner from this Mac
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let rotator = try #require(h.runner.chunkRotator)
        let released = Harness.Box(false)
        h.client.onStop = { while !released.value { await Task.yield() } }
        h.client.stopError = FakeCaptureError()
        let coordinator = h.coordinator
        let stopping = Task { await coordinator.stopRecording() }
        await Harness.until { h.client.stopCalls == 1 }
        h.coordinator.systemWillSleep(at: Date(timeIntervalSince1970: 1_000))
        h.coordinator.systemDidWake(at: Date(timeIntervalSince1970: 1_060))
        await Harness.until { h.client.powerEvents.count == 2 }
        #expect(h.client.powerEvents == ["sleep", "wake"])
        #expect(h.client.recordedEvents.contains { $0.kind == .systemWake })
        #expect(h.client.rotateCalls == 0 && rotator.activeTimerForTesting == nil, "no rotation, no timer")
        #expect(h.appState.interruptionWarning == nil, "no banner")
        // L review 109: the gap is still recorded, in the session.
        let processor = try #require(h.runner.chunkProcessor)
        var gaps: [CaptureGap] = []   // the gap's Task lands shortly: polled, bounded
        for _ in 0..<200 where gaps.isEmpty {
            gaps = await processor.getSessionState().gaps
            if gaps.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(gaps.count == 1 && gaps.first?.seconds == 60 && gaps.first?.reason == "sleep")
        released.value = true
        await stopping.value
        #expect(rotator.activeTimerForTesting == nil)
    }

    /// L10 review 55: a didWake that never arrives must not silently switch app-side monitoring off. After
    /// ~30 s of AWAKE time with no wake, an implicit wake runs: the gap is recorded, the helper told, the
    /// rotation and the poll resumed.
    @Test func aLostWakeIsHealedAfterThirtySecondsOfAwakeTime() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        let clock = ManualTestClock()
        h.coordinator.wakeWatchdogClock = clock
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try FileManager.default.createDirectory(at: try #require(h.client.startCalls.first).outputDirectory, withIntermediateDirectories: true)
        h.coordinator.systemWillSleep(at: Date().addingTimeInterval(-3600))   // asleep an hour: the lost wake came ~30 s ago
        await Harness.until { clock.pendingSleeps > 0 }
        clock.advance(by: .seconds(29))
        for _ in 0..<50 { await Task.yield() }
        #expect(h.client.powerEvents == ["sleep"], "29 s awake: still waiting for the wake")
        clock.advance(by: .seconds(1))
        await Harness.until { h.client.powerEvents.count == 2 }
        #expect(h.client.powerEvents == ["sleep", "wake"])
        #expect(h.client.recordedEvents.contains { $0.kind == .systemWake && $0.detail["implicit"] == "true" })
        await Harness.until { h.client.rotateCalls == 1 }
        #expect(h.client.rotateCalls == 1 && h.runner.chunkRotator?.activeTimerForTesting != nil, "rotation resumed")
        // L review 109: the lost wake is placed 30 s (the timeout, in awake time) before the implicit one.
        let gap = try #require(await h.runner.chunkProcessor?.getSessionState().gaps.first)
        #expect(abs(gap.end.timeIntervalSince(Date().addingTimeInterval(-30))) < 2, "\(gap.end)")
    }

    /// … and a wake that does arrive disarms it: one wake, never two.
    @Test func aWakeInTimeDisarmsTheLostWakeWatchdog() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        let clock = ManualTestClock()
        h.coordinator.wakeWatchdogClock = clock
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.coordinator.systemWillSleep(at: Date())
        await Harness.until { clock.pendingSleeps > 0 }
        h.coordinator.systemDidWake(at: Date())
        await Harness.until { clock.pendingSleeps == 0 }
        clock.advance(by: .seconds(60))
        for _ in 0..<50 { await Task.yield() }
        #expect(h.client.powerEvents == ["sleep", "wake"])
    }

    /// L10 review 57: the recording ends between the sleep and the wake — the helper still gets its "wake"
    /// (the pairing holds), and the late didWake then does nothing: no second wake, no gap, no restart.
    @Test func aRecordingThatEndsWhileAsleepStillSendsTheWake() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.coordinator.systemWillSleep(at: Date())
        h.client.stopError = FakeCaptureError()
        await h.coordinator.stopRecording()
        await Harness.until { h.client.powerEvents.count == 2 }
        #expect(h.client.powerEvents == ["sleep", "wake"])
        h.coordinator.systemDidWake(at: Date())
        for _ in 0..<50 { await Task.yield() }
        #expect(h.client.powerEvents == ["sleep", "wake"])
        #expect(!h.client.recordedEvents.contains { $0.kind == .systemWake })
    }

    /// L10 review 58: every Quit goes through the coordinator — a Quit from the setup panel during a Flow A
    /// re-attach asks first and stops the recording; no coordinator (nothing can be recording) just quits.
    @Test func everyQuitGoesThroughTheCoordinator() async throws {
        #expect(await RecordingCoordinator.quitGate(nil, confirm: { Issue.record("nothing to confirm"); return false }))
        let h = try Harness()
        defer { tearDown(h) }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date(); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.isCapturingResult = true
        await h.coordinator.recoverAtLaunch()
        #expect(h.appState.isRecording, "re-attached")
        h.client.stopError = FakeCaptureError()
        #expect(await RecordingCoordinator.quitGate(h.coordinator, confirm: { false }) == false)
        #expect(h.client.stopCalls == 0)
        #expect(await RecordingCoordinator.quitGate(h.coordinator, confirm: { true }))
        #expect(h.client.stopCalls == 1)
    }

    /// L10 review 59: the Mac does not idle-sleep until the transcript is finished — the finalize included.
    @Test func idleSleepIsPreventedUntilTheTranscriptIsFinished() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try stopReturnsTheFirstChunk(h)
        h.runner.finalizeDelayForTesting = .milliseconds(400)
        let coordinator = h.coordinator
        let stopping = Task { await coordinator.stopRecording() }
        await Harness.until { h.appState.isTranscribing }
        for _ in 0..<20 { await Task.yield() }
        #expect(h.coordinator.preventsIdleSleep, "still finishing the transcript")
        await stopping.value
        await Harness.until { !h.coordinator.preventsIdleSleep }
        #expect(!h.coordinator.preventsIdleSleep && h.appState.isIdle)
    }

    /// L10 review 60: a Quit whose stop hangs still quits within its (injectable) bound — never stuck.
    @Test func aQuitWhoseStopHangsReturnsWithinItsBound() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.coordinator.quitStopBound = .milliseconds(200)
        h.client.onStop = { try? await Task.sleep(for: .seconds(3)) }
        let began = ContinuousClock.now
        #expect(await h.coordinator.prepareForQuit(confirm: { true }))
        #expect(ContinuousClock.now - began < .milliseconds(600))
        #expect(RecordingSentinel.read(directory: h.tmp)?.quitDuringFinalize == true, "the next launch finishes it, as a quit")
    }

    /// L10 review 60: a Quit while a Stop is already in flight waits for THAT stop (it used to return at once,
    /// "Stop already in progress") — the transcript is finished before the app goes.
    @Test func aQuitDuringAStopInFlightWaitsForIt() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try stopReturnsTheFirstChunk(h)
        let released = Harness.Box(false)
        h.client.onStop = { while !released.value { await Task.yield() } }
        let coordinator = h.coordinator
        let stopping = Task { await coordinator.stopRecording() }
        await Harness.until { h.client.stopCalls == 1 }
        let quit = Harness.Box<Bool?>(nil)
        let quitting = Task { quit.value = await coordinator.prepareForQuit(confirm: { true }) }
        for _ in 0..<50 { await Task.yield() }
        #expect(quit.value == nil, "waiting for the stop in flight")
        released.value = true
        let releasedAt = ContinuousClock.now
        await stopping.value
        await quitting.value
        #expect(quit.value == true && h.presented.value.count == 1 && h.client.stopCalls == 1)
        #expect(ContinuousClock.now - releasedAt < .milliseconds(500), "awaited, not polled (L review 109)")
    }

    /// L10 review 60: a long user Quit says so — a notification once it outlasts `quitFeedbackDelay`, and the
    /// menu's status while it runs.
    @Test func aLongQuitSaysSo() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try stopReturnsTheFirstChunk(h)
        h.coordinator.quitFeedbackDelay = .milliseconds(50)
        let coordinator = h.coordinator
        let quittingSeen = Harness.Box(false)
        h.client.onStop = { quittingSeen.value = coordinator.isQuitting; try? await Task.sleep(for: .milliseconds(300)) }
        #expect(await h.coordinator.prepareForQuit(confirm: { true }))
        #expect(quittingSeen.value && !h.coordinator.isQuitting)
        #expect(h.notified.value.contains { $0.title == "Quitting Parley" })
    }

    /// … and a quick one does not.
    @Test func aQuickQuitSaysNothing() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try stopReturnsTheFirstChunk(h)
        h.coordinator.quitFeedbackDelay = .seconds(5)
        #expect(await h.coordinator.prepareForQuit(confirm: { true }))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!h.notified.value.contains { $0.title == "Quitting Parley" })
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

    /// 35: nothing retries by itself (within this test's window — a test cannot prove "never"); the event —
    /// a volume mount, a wake, a launch, a recording's end — does. There is no retry timer in the code.
    @Test func aReturnedFolderWaitsForAnEvent() async throws {
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
        // Held (L review 81): pending, marked stopping — salvage-only — and out of the slot a next Start writes.
        let held = try #require(RecordingSentinel.readPending(directory: h.tmp).first)
        #expect(held.stopping && RecordingSentinel.read(directory: h.tmp) == nil)
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
        #expect(RecordingSentinel.readPending(directory: h.tmp).count == 1, "kept (L review 81: held, not left in the slot)")
    }

    /// L review 81: a failed start whose helper will not stop is HELD — marked stopping, pending — so a second
    /// Start cannot overwrite it and leave the stuck helper untracked.
    @Test func aHeldFailedStartSurvivesTheNextStart() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { h.runner.stopChunkRotation(); h.runner.teardownChunkedPipeline() }
        h.runner.failSetupForTesting = true
        h.coordinator.helperStopDeadline = .milliseconds(100)
        h.client.onStop = { try? await Task.sleep(for: .seconds(1)) }
        await h.coordinator.startRecording(sessionName: "first", microphoneDeviceId: nil)
        let first = try #require(h.client.startCalls.first)
        h.runner.failSetupForTesting = false
        h.client.onStop = nil
        await h.coordinator.startRecording(sessionName: "second", microphoneDeviceId: nil)
        #expect(h.appState.isRecording)
        let held = RecordingSentinel.readPending(directory: h.tmp)
        #expect(held.map { stripSegmentSuffix($0.systemAudioPath) }.contains { $0.hasSuffix(first.sessionId) }, "still tracked")
        #expect(held.allSatisfy { $0.stopping })
    }

    /// L review 81: … and a relaunch within the resume window SALVAGES it — never resumes a meeting the user
    /// was told had failed.
    @Test func aHeldFailedStartIsSalvagedNeverResumed() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        h.runner.failSetupForTesting = true
        h.coordinator.helperStopDeadline = .milliseconds(100)
        h.client.onStop = { try? await Task.sleep(for: .seconds(1)) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.runner.failSetupForTesting = false
        h.client.onStop = nil   // the helper lets go now
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.count == 1, "never resumed")
        #expect(RecordingSentinel.readPending(directory: h.tmp).isEmpty && h.appState.isIdle)
        #expect(h.appState.activeAlarms[.recordingStopped] != nil)
    }

    /// L review 82: a failed resume whose helper will not stop is tracked ONCE — the newest copy, in the list —
    /// never in the slot and the list both.
    @Test func aHeldFailedResumeIsTrackedOnce() async throws {
        let h = try Harness()
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-20); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        h.runner.failSetupForTesting = true   // the resume's capture starts, its pipeline cannot be built
        h.coordinator.helperStopDeadline = .milliseconds(100)
        h.client.onStop = { try? await Task.sleep(for: .seconds(1)) }
        await h.coordinator.recoverAtLaunch()
        #expect(RecordingSentinel.read(directory: h.tmp) == nil, "not in the slot")
        let held = RecordingSentinel.readPending(directory: h.tmp)
        #expect(held.count == 1 && held.first?.sessionKey == s.sessionKey)
        #expect(held.first?.chunkIndex == 1, "the newest copy: the resume's")
        #expect(held.first?.stopping == true, "held: salvage-only (L review 135)")
    }

    /// L review 84: a held session is released only when the helper's stop says it let go — never on a ping. A
    /// ping answering "not capturing" while the stop still hangs salvages nothing.
    @Test func aHeldSessionIsNeverReleasedOnAPing() async throws {
        let h = try Harness()
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID(); s.stopping = true
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.captureStateResult = .notCapturing   // the ping says so…
        h.coordinator.helperStopDeadline = .milliseconds(100)
        h.client.onStop = { try? await Task.sleep(for: .seconds(1)) }   // …but the helper does not let go
        await h.coordinator.recoverAtLaunch()
        #expect(h.presented.value.isEmpty && h.client.finalizeCalls.isEmpty, "never salvaged on a ping")
        #expect(pending(h).map(\.sessionKey) == [s.sessionKey])
        await h.coordinator.retryPendingSessions()
        #expect(h.presented.value.isEmpty && pending(h).count == 1, "nor at the retry")
        h.client.onStop = nil
        await h.coordinator.retryPendingSessions()
        #expect(pending(h).isEmpty && !h.client.finalizeCalls.isEmpty, "released once the stop said so")
    }

    /// L review 88: a relaunch that holds a session for its helper marks the helper's mic, so no level meter
    /// opens it (#192) — and releases it once the helper let go.
    @Test func aHeldSessionMarksTheHelpersMicUntilItLetsGo() async throws {
        let h = try Harness()
        var s = try h.writeSentinel(micDeviceUID: "mic-7")
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID(); s.stopping = true
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.isCapturingResult = true
        h.coordinator.helperStopDeadline = .milliseconds(100)
        h.client.onStop = { try? await Task.sleep(for: .seconds(1)) }
        await h.coordinator.recoverAtLaunch()
        #expect(h.recordingMic.current == .some("mic-7"))
        h.client.onStop = nil
        h.client.isCapturingResult = false
        await h.coordinator.retryPendingSessions()
        #expect(h.recordingMic.current == .none)
    }

    /// L review 83: launch recovery and the pending retries are ONE at a time. A retry asked for while the
    /// relaunch is still deciding (here: during its ping) defers — it never stops the crashed app's live helper
    /// as a "stray" — and runs once the gate is free.
    @Test func aRetryDuringLaunchRecoveryDefers() async throws {
        let h = try Harness()
        defer { h.runner.stopChunkRotation(); h.runner.teardownChunkedPipeline() }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        let other = h.tmp.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try RecordingSentinel.writePending([RecordingSentinel(
            startedAt: Date(), sessionName: "Old", systemAudioPath: other.appendingPathComponent("old-0.wav").path,
            micAudioPath: other.appendingPathComponent("old-0_mic.wav").path, segment: 1, chunkIndex: 0, stopping: true)], directory: h.tmp)
        h.client.isCapturingResult = true   // the crashed app's helper is still recording
        let coordinator = h.coordinator
        let retried = Harness.Box(false)
        h.client.onIsCapturing = {
            guard !retried.value else { return }
            retried.value = true
            await coordinator.retryPendingSessions()   // a volume mounted just now
        }
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.stopCalls == 0, "the live helper was never stopped as a stray")
        #expect(h.appState.isRecording, "re-attached")
        #expect(pending(h).count == 1, "the retry waits for the recording to end")
    }

    /// L review 90: one retry that salvages several sessions says so ONCE — one row naming them all — and
    /// every transcript is presented (the app queues the rename panels).
    @Test func severalSalvagesInOneRetryAreOneRow() async throws {
        let h = try Harness()
        var sessions: [RecordingSentinel] = []
        for name in ["one", "two"] {
            let dir = h.tmp.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: name, meetingStart: Date(), chunkIndices: [0])
            sessions.append(RecordingSentinel(startedAt: Date(), sessionName: name, systemAudioPath: dir.appendingPathComponent("\(name)-0.wav").path,
                                              micAudioPath: dir.appendingPathComponent("\(name)-0_mic.wav").path, segment: 1, chunkIndex: 0, stopping: true))
        }
        try RecordingSentinel.writePending(sessions, directory: h.tmp)
        await h.coordinator.retryPendingSessions()
        #expect(h.presented.value.count == 2)
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.hasPrefix("2 earlier recordings were recovered:"), "\(row)")
        #expect(row.contains("one.json") && row.contains("two.json"), "\(row)")
    }

    /// L review 89: an unreadable pending list is set aside and said, never silently dropped.
    @Test func anUnreadablePendingListIsSaid() async throws {
        let h = try Harness()
        try Data("{ not a list".utf8).write(to: h.tmp.appendingPathComponent("pending-sessions.json"))
        await h.coordinator.retryPendingSessions()
        // Its own row, never "Recording STOPPED" (L review 249).
        #expect(h.appState.activeAlarms[.pendingListUnreadable]?.message.contains("could not read its list of unfinished recordings") == true)
        let aside = try FileManager.default.contentsOfDirectory(atPath: h.tmp.path).filter { $0.hasPrefix("pending-sessions.unreadable") }
        #expect(aside.count == 1)
    }

    /// L review 86: an older-format recording's STOPPED time is when its file was last written, never its start.
    @Test func aLegacyRecordingIsStoppedWhenItsFileWasLastWritten() async throws {
        let h = try Harness()
        let outDir = h.tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let started = Date().addingTimeInterval(-3600)
        let sentinel = RecordingSentinel(
            startedAt: started, sessionName: "Legacy", systemAudioPath: outDir.appendingPathComponent("legacy.wav").path,
            micAudioPath: outDir.appendingPathComponent("legacy_mic.wav").path, segment: 1, chunkIndex: 0)
        try RecordingSentinel.write(sentinel, directory: h.tmp)
        try Data(count: 4096).write(to: URL(fileURLWithPath: sentinel.systemAudioPath))
        let lastWrite = started.addingTimeInterval(1800)
        try FileManager.default.setAttributes([.modificationDate: lastWrite], ofItemAtPath: sentinel.systemAudioPath)
        await h.coordinator.recoverAtLaunch()
        let message = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(message.contains(RecoveryMessages.clock(lastWrite)) && !message.contains(RecoveryMessages.clock(started)), "\(message)")
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

    /// L review 71: `resolvingSymlinksInPath()` leaves a DANGLING link alone — `~/Recordings → /Volumes/Ext/…`
    /// with the drive unplugged read as a writable home folder. Every link is substituted, dangling or not,
    /// before the `/Volumes` check.
    @Test func aDanglingLinkToAnAbsentVolumeIsUnreachable() {
        let probe = RecordingCoordinator.FolderProbe(
            exists: { ["/", "/Users", "/Users/x", "/Volumes"].contains($0.path) }, isWritable: { _ in true }, isVolumeRoot: { _ in false },
            symlinkDestination: { $0.path == "/Users/x/Recordings" ? "/Volumes/Ext/Recordings" : nil })
        #expect(RecordingCoordinator.folderStatus(URL(fileURLWithPath: "/Users/x/Recordings/day"), probe: probe) == .unreachable)
    }

    /// … on the real file system too: a link to a volume that is not mounted.
    @Test func aRealDanglingLinkToAnAbsentVolumeIsUnreachable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dangling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("Recordings")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Volumes/Absent-\(UUID().uuidString)/Recordings")
        #expect(!RecordingCoordinator.folderReachable(link.appendingPathComponent("2026-09-25")))
    }

    /// A relative link resolves against its own folder.
    @Test func aRelativeLinkResolvesAgainstItsFolder() {
        let probe = RecordingCoordinator.FolderProbe(
            exists: { _ in true }, isWritable: { _ in true }, isVolumeRoot: { $0.path == "/Volumes/Ext" },
            symlinkDestination: { $0.path == "/Users/x/Recordings" ? "../../Volumes/Ext/Rec" : nil })
        #expect(RecordingCoordinator.resolvedFolder(URL(fileURLWithPath: "/Users/x/Recordings/day"), probe: probe).path == "/Volumes/Ext/Rec/day")
    }

    /// L review 79: a folder that is there but cannot be written is its own case — a permissions problem, not
    /// a missing drive.
    @Test func aPresentFolderThatCannotBeWrittenIsNotWritableNotUnreachable() {
        let readOnly = RecordingCoordinator.FolderProbe(exists: { _ in true }, isWritable: { _ in false }, isVolumeRoot: { _ in false })
        #expect(RecordingCoordinator.folderStatus(URL(fileURLWithPath: "/Users/x/Recordings/day"), probe: readOnly) == .notWritable)
        // L review 126: once any mount check has passed, a missing folder whose nearest existing ancestor cannot
        // be written is a permissions problem too — a read-only volume is not a missing drive.
        let missing = RecordingCoordinator.FolderProbe(exists: { $0.path == "/" }, isWritable: { _ in false }, isVolumeRoot: { _ in false })
        #expect(RecordingCoordinator.folderStatus(URL(fileURLWithPath: "/Users/x/Recordings/day"), probe: missing) == .notWritable)
        let readOnlyVolume = RecordingCoordinator.FolderProbe(
            exists: { ["/", "/Volumes", "/Volumes/Ext"].contains($0.path) }, isWritable: { _ in false }, isVolumeRoot: { $0.path == "/Volumes/Ext" })
        #expect(RecordingCoordinator.folderStatus(URL(fileURLWithPath: "/Volumes/Ext/Recordings/day"), probe: readOnlyVolume) == .notWritable)
    }

    /// L review 125: a symbolic-link cycle is never "reachable": hitting the 40-link cap means unreachable.
    @Test func aSymlinkCycleIsUnreachable() {
        let cycle = RecordingCoordinator.FolderProbe(
            exists: { _ in true }, isWritable: { _ in true }, isVolumeRoot: { _ in false },
            symlinkDestination: { ["/Users/x/a": "/Users/x/b", "/Users/x/b": "/Users/x/a"][$0.path] })
        #expect(RecordingCoordinator.folderStatus(URL(fileURLWithPath: "/Users/x/a/day"), probe: cycle) == .unreachable)
    }

    /// … on the real file system too.
    @Test func aRealSymlinkCycleIsUnreachable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("a").path, withDestinationPath: dir.appendingPathComponent("b").path)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("b").path, withDestinationPath: dir.appendingPathComponent("a").path)
        #expect(RecordingCoordinator.folderStatus(dir.appendingPathComponent("a/day")) == .unreachable)
    }

    /// L review 128: a LIVE link to a mounted volume is reachable.
    @Test func aLiveLinkToAMountedVolumeIsReachable() {
        let probe = RecordingCoordinator.FolderProbe(
            exists: { _ in true }, isWritable: { _ in true }, isVolumeRoot: { $0.path == "/Volumes/Ext" },
            symlinkDestination: { $0.path == "/Users/x/Recordings" ? "/Volumes/Ext/Recordings" : nil })
        #expect(RecordingCoordinator.folderStatus(URL(fileURLWithPath: "/Users/x/Recordings/day"), probe: probe) == .reachable)
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
    /// progress: the stop path owns it all, no restart. The processor skips a same-file duplicate silently,
    /// so the single ingest is shown by the crash path never running at all (no retry recorded) — it is the
    /// only other ingester (L review, RCT:3310).
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
        #expect(h.client.retryEvents.isEmpty, "the crash path never ran: nothing else ingested the chunk")
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
        h.runner.finalizeDelayForTesting = .milliseconds(600)
        h.coordinator.quitStopBound = .milliseconds(100)   // the finalize outlasts the quit's bound (L review 111)
        let coordinator = h.coordinator
        let stopping = Task { await coordinator.stopRecording() }
        await Harness.until { h.appState.isTranscribing }
        #expect(await h.coordinator.prepareForQuit(confirm: { Issue.record("no question while finishing"); return true }))
        #expect(RecordingSentinel.read(directory: h.tmp)?.quitDuringFinalize == true)
        // Awaited, never cancelled (L review, RCT:3329): a cancelled Task keeps running into the next test.
        await stopping.value
        #expect(h.presented.value.count == 1 && RecordingSentinel.read(directory: h.tmp) == nil, "the finalize still finished")
    }

    /// L review 111 (M6): a Quit during the finalize is the same as a Quit during the helper's stop — nothing asked
    /// (the recording is already stopping) — and it waits for the transcript, within the same bound as any quit.
    @Test func aQuitDuringFinalizeWaitsForItWithinTheBound() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let call = try #require(h.client.startCalls.first)
        try FileManager.default.createDirectory(at: call.outputDirectory, withIntermediateDirectories: true)
        let sys = call.outputDirectory.appendingPathComponent(call.baseName + ".wav")
        try Harness.headerOnlyWAV().write(to: sys)
        h.client.stopResult = AudioPaths(systemAudio: sys, micAudio: call.outputDirectory.appendingPathComponent(call.baseName + "_mic.wav"))
        h.runner.finalizeDelayForTesting = .milliseconds(300)
        let coordinator = h.coordinator
        let stopping = Task { await coordinator.stopRecording() }
        await Harness.until { h.appState.isTranscribing }
        #expect(await h.coordinator.prepareForQuit(confirm: { Issue.record("no question while finishing"); return true }))
        #expect(h.presented.value.count == 1 && RecordingSentinel.read(directory: h.tmp) == nil, "the transcript was finished before the quit")
        await stopping.value
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
        try Harness.headerOnlyWAV().write(to: dir(s).appendingPathComponent("sess-1_mic.wav"))
        h.client.rotateReply = { _ in (live.path, self.dir(s).appendingPathComponent("sess-1_mic.wav").path) }   // the helper seals the live file
        let processor = try #require(h.runner.chunkProcessor)
        await rotator.rotateForTesting()
        #expect(h.client.rotateCalls == 1 && rotator.currentChunkInfo.index == 2, "the live file handed over")
        await processor.awaitAllProcessed()
        #expect(await processor.getSessionState().chunks.map(\.index).contains(1), "chunk 1 processed from the live file")
        h.freeBytes.value = 1_000   // below one chunk
        await rotator.rotateForTesting()
        await h.coordinator.awaitRotationDiskCheckForTesting()
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
        let s = try freshSentinel(h)
        await h.coordinator.recoverAtLaunch()
        // L review 100: the SAME session — its id and its folder — adopted, then started.
        let at = try #require(h.client.startCalls.first).outputDirectory.standardized.path
        #expect(at == dir(s).standardized.path)
        #expect(h.client.sessionCalls == ["adopt:sess@\(at)", "start:sess@\(at)"])
    }

    @Test func aReattachAdoptsTheSession() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try freshSentinel(h)
        h.client.isCapturingResult = true
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.sessionCalls == ["adopt:sess@\(dir(s).standardized.path)"], "the session's own folder (L review 100)")
    }

    /// L review 72: a crash reported while the re-attach adopts its session (an await) finds the chunk pipeline
    /// already built — the crash path names its restart from the live rotator — never a pipeline built after it.
    @Test func aCrashWhileTheReattachAdoptsIsRecoveredOnTheLivePipeline() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try freshSentinel(h)
        try Harness.headerOnlyWAV().write(to: dir(s).appendingPathComponent("sess-1.wav"))   // the helper's live file
        h.client.isCapturingResult = true
        let client = h.client
        client.onAdopt = {
            client.onAdopt = nil
            client.onServiceCrash?()                  // the helper dies right then
            await Harness.until { client.startCalls.count == 1 }
        }
        await h.coordinator.recoverAtLaunch()
        let restart = try #require(h.client.startCalls.first)
        let rotator = try #require(h.runner.chunkRotator)
        #expect(rotator.currentBaseName == restart.baseName, "the rotator names the file the restarted helper writes")
        #expect(restart.baseName == "sess-2", "past the live chunk")
        #expect(h.appState.isRecording)
        // L review 128: the live sess-1 the crash cut short was re-ingested on the live pipeline.
        let processor = try #require(h.runner.chunkProcessor)
        await processor.awaitAllProcessed()
        #expect(await processor.getSessionState().chunks.map(\.index).contains(1))
    }

    /// L review 72: a Stop while the re-attach adopts finishes the recording ONCE, on the live pipeline, and
    /// leaves nothing running on the idle app afterwards.
    @Test func aStopWhileTheReattachAdoptsFinishesOnceAndLeavesNothingRunning() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try freshSentinel(h)
        let live = dir(s).appendingPathComponent("sess-1.wav"), liveMic = dir(s).appendingPathComponent("sess-1_mic.wav")
        try Harness.headerOnlyWAV().write(to: dir(s).appendingPathComponent("sess-0.wav"))   // sealed, never processed
        try Harness.headerOnlyWAV().write(to: live); try Harness.headerOnlyWAV().write(to: liveMic)
        h.client.isCapturingResult = true
        h.client.stopResult = AudioPaths(systemAudio: live, micAudio: liveMic)
        let client = h.client, coordinator = h.coordinator, runner = h.runner
        client.onAdopt = {
            client.onAdopt = nil
            await coordinator.stopRecording()
        }
        let chunks = Harness.Box<[ProcessedChunk]>([])
        client.onFinalizeDiagnostics = { chunks.value = await runner.chunkProcessor?.getSessionState().chunks ?? [] }
        await h.coordinator.recoverAtLaunch()
        #expect(h.appState.isIdle && h.client.stopCalls == 1)
        // L review 128: the orphan sess-0 and the live sess-1 are both in the record, each from its own audio.
        #expect(chunks.value.map(\.index).sorted() == [0, 1], "\(chunks.value.map(\.index))")
        #expect(h.runner.chunkRotator == nil && h.runner.chunkProcessor == nil, "no pipeline left running on an idle app")
        #expect(h.presented.value.count == 1)
        #expect(!h.client.launchRecoveries.contains { $0["flow"] == "A" }, "the stop owned the session: nothing more after the adopt")
    }

    /// L review 76: a re-attach whose chunk pipeline cannot be built says so — an anomaly on record and the
    /// rotation alarm — never only a log line.
    @Test func aReattachThatCannotBuildItsPipelineRaisesTheAlarm() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try freshSentinel(h)
        h.client.isCapturingResult = true
        h.runner.failSetupForTesting = true
        await h.coordinator.recoverAtLaunch()
        // L review 121: the anomaly is recorded into the BOUND session — the adopt that follows, whose bind of a
        // new session resets the evidence, would otherwise wipe it.
        #expect(h.client.evidenceOrder.prefix(2) == ["bind:sess", "adopt:sess"])
        #expect(h.appState.isRecording, "still re-attached: the helper keeps capturing")
        #expect(h.appState.activeAlarms[.rotationFailed]?.message.contains("re-attached recording can’t rotate") == true)
        #expect(h.client.recordedEvents.contains { $0.kind == .rotationFailed && $0.severity == .anomaly })
    }

    /// L review 77: the first rotation after a re-attach is due when the live chunk is — its start plus one
    /// chunk — not a full chunk from the re-attach; at once when that time has passed.
    @Test func theFirstRotationAfterAReattachIsDueWithTheLiveChunk() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try freshSentinel(h)
        let live = dir(s).appendingPathComponent("sess-1.wav")
        try Harness.headerOnlyWAV().write(to: live)
        let began = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 120).rounded(.down))
        try FileManager.default.setAttributes([.creationDate: began], ofItemAtPath: live.path)
        h.client.isCapturingResult = true
        await h.coordinator.recoverAtLaunch()
        let timer = try #require(h.runner.chunkRotator?.activeTimerForTesting)
        let chunk = TimeInterval(h.config.config.validatedChunkDuration * 60)
        #expect(abs(timer.fireDate.timeIntervalSince(began.addingTimeInterval(chunk))) < 1, "\(timer.fireDate) vs \(began.addingTimeInterval(chunk))")
    }

    /// L review 128: … and at once when the live chunk is already overdue.
    @Test func anOverdueLiveChunkRotatesAtOnceAfterAReattach() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try freshSentinel(h)
        let live = dir(s).appendingPathComponent("sess-1.wav")
        try Harness.headerOnlyWAV().write(to: live)
        let chunk = TimeInterval(h.config.config.validatedChunkDuration * 60)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-chunk - 60)], ofItemAtPath: live.path)
        h.client.isCapturingResult = true
        await h.coordinator.recoverAtLaunch()
        await Harness.until { h.client.rotateCalls == 1 }
        #expect(h.client.rotateCalls == 1, "overdue: rotated at once")
    }

    /// L11 review 63 (pinned; L follow-up 43 made the re-attach adopt): a later helper crash restarts the SAME
    /// session — its recovery, retry and drained events are never reset away.
    @Test func aReattachedRecordingsCrashRestartKeepsItsSession() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try freshSentinel(h)
        h.client.isCapturingResult = true
        await h.coordinator.recoverAtLaunch()
        h.client.isCapturingResult = false
        await h.coordinator.handleXPCCrash()
        let at = dir(s).standardized.path
        #expect(h.client.startCalls.first?.outputDirectory.standardized.path == at)
        #expect(h.client.sessionCalls == ["adopt:sess@\(at)", "start:sess@\(at)"], "the same id AND folder (L review 100)")
        #expect(h.appState.isRecording)
    }

    /// L11 review 68: a start that never became a recording leaves no evidence behind (no orphan live log)…
    @Test func aFailedStartDiscardsItsSessionEvidence() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        h.client.startError = FakeCaptureError()
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let call = try #require(h.client.startCalls.first)
        #expect(h.client.discardedSessions == [call.sessionId])
    }

    /// … but one whose helper would not let go keeps it: the next launch salvages that session, evidence included.
    @Test func aFailedStartWhoseHelperHoldsOnKeepsItsEvidence() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        h.coordinator.startDeadline = .milliseconds(150)
        h.coordinator.helperStopDeadline = .milliseconds(100)
        h.client.onStartAsync = { try? await Task.sleep(for: .seconds(2)) }
        h.client.onStop = { try? await Task.sleep(for: .seconds(2)) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(h.client.discardedSessions.isEmpty && RecordingSentinel.readPending(directory: h.tmp).count == 1)
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
        // The positive control (L review 78): with the recovery over, the timer refreshes it again.
        await Harness.until { RecordingSentinel.read(directory: h.tmp)?.lastAliveAt != stale }
        #expect(RecordingSentinel.read(directory: h.tmp)?.lastAliveAt != stale)
    }
}

// MARK: - L round A: the H2 + R2 merge wiring (items 26, 91)

@MainActor
@Suite struct RecordingCoordinatorMergeWiringTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }

    /// L review 91: a stop answered "Refused: capture is starting or stopping" is a stop already under way in
    /// the helper — asked again within the bound, never read as a helper that will not let go (which would
    /// hold the session and say it could not be stopped).
    @Test func aStopRefusedWhileTheHelperIsStoppingIsAskedAgain() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        let s = try h.writeSentinel()
        try RecordingSentinel.writePending([s], directory: h.tmp)
        RecordingSentinel.delete(directory: h.tmp)
        let client = h.client
        client.onStop = { client.stopError = client.stopCalls == 1 ? RefusedStoppingError() : nil }
        await h.coordinator.retryPendingSessions()
        #expect(h.client.stopCalls == 2, "asked again")
        #expect(RecordingSentinel.readPending(directory: h.tmp).isEmpty, "salvaged once the helper let go")
        #expect(h.appState.activeAlarms[.recordingStopped]?.message.contains("couldn’t stop") != true)
    }

    /// L review 91 (item 48): the helper abandoned a start at its own deadline — the audio system, said as
    /// such, never the wire text.
    @Test func aStartTheHelperAbandonedIsSaidAsTheAudioSystem() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        h.client.startError = HelperReplyError(reply: CaptureReplies.startTimedOut)
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(h.appState.errorMessage == "Parley couldn’t start recording — the audio system didn’t respond.")
        #expect(h.appState.isIdle && RecordingSentinel.read(directory: h.tmp) == nil)
    }

    /// … a stop or disconnect during the start cancelled it: said, and nothing is left behind.
    @Test func aStartCancelledWhileStartingSaysSo() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        h.client.startError = HelperReplyError(reply: CaptureReplies.cancelledWhileStarting)
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(h.appState.errorMessage == "Parley couldn’t start recording — the start was cancelled.")
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
    }

    /// … and "Capture already in progress": the helper is still busy with an earlier capture (a held
    /// session's). Said as such, and the mic that capture holds stays marked (#192) — never released by a
    /// start that did not get the helper.
    @Test func aStartRefusedBecauseTheHelperIsBusyKeepsItsMicMarked() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        h.recordingMic.set("held-mic")   // an earlier capture the helper has not let go of
        h.client.startError = HelperReplyError(reply: CaptureReplies.alreadyInProgress)
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "new-mic")
        #expect(h.appState.errorMessage == "Parley couldn’t start recording — the capture helper is still busy with an earlier recording.")
        #expect(h.recordingMic.current == .some("held-mic"))
        #expect(h.client.stopCalls == 0, "the busy capture is not this start's to stop")
    }

    /// L follow-up 26 (R2's `onSessionWriteSucceeded`): `sessionWriteFailed` clears on the next SUCCESSFUL
    /// session.json write — it is not stuck until the recording ends.
    @Test func aSuccessfulSessionWriteClearsTheWriteAlarm() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let outDir = try #require(h.client.startCalls.first).outputDirectory
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: outDir.path)
        await h.runner.recordCaptureGap(CaptureGap(start: Date().addingTimeInterval(-9), end: Date().addingTimeInterval(-8), reason: "sleep"))
        #expect(h.appState.activeAlarms[.sessionWriteFailed] != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outDir.path)
        await h.runner.recordCaptureGap(CaptureGap(start: Date().addingTimeInterval(-5), end: Date(), reason: "sleep"))
        #expect(h.appState.activeAlarms[.sessionWriteFailed] == nil, "the progress file is written again")
        #expect(h.appState.isRecording)
    }
}

// MARK: - L round A: a finalized session is never processed twice; the salvage says what really happened (69, 93, 93b, 94, 120, 136)

@MainActor
@Suite struct RecordingCoordinatorFinalizedGateTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }

    private func slotSentinel(_ h: Harness, alive: TimeInterval, boot: String? = BootSession.currentUUID(), stopping: Bool = false) throws -> RecordingSentinel {
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-alive)
        s.bootSessionUUID = boot
        s.stopping = stopping
        try RecordingSentinel.write(s, directory: h.tmp)
        return s
    }

    private func outDir(_ s: RecordingSentinel) -> URL { URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent() }

    /// A session finalized the way a stop finalizes it (transcript, marker, session.json gone), then the
    /// leftovers a crash between the transcript and the sentinel's delete can leave: session.json, no TXT.
    private func finalizedWithLeftovers(_ h: Harness, _ s: RecordingSentinel, issues: [ChunkIssue] = []) async throws -> URL {
        let dir = outDir(s)
        try writeSession(dir: dir, meetingStart: s.startedAt, issues: issues)
        let result = try #require(try await ChunkedSessionRecovery.recover(
            outputDirectory: dir, sessionId: "sess", config: h.config.config, transcriber: FakeEngine(), diarizer: FakeDiarizer(),
            runner: h.runner))
        #expect(CrashRecoveryPlanner.isFinalized(outputDirectory: dir, sessionId: "sess"))
        try writeSession(dir: dir, meetingStart: s.startedAt, issues: issues)   // the leftover progress file
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("sess.txt"))
        return result.jsonPath
    }

    private func writeSession(dir: URL, meetingStart: Date, issues: [ChunkIssue]) throws {
        let chunk = ProcessedChunk(index: 0, startTime: meetingStart, audioPath: "sess-0.m4a",
                                   segments: [.init(start: 0, end: 5, text: "chunk 0", speaker: "Speaker 1", source: "remote", qualityScore: 1)],
                                   speakerDatabase: ["Speaker 1": [1, 0, 0]], isDualStream: false, issues: issues)
        try SessionState.write(SessionState(sessionId: "sess", meetingStart: meetingStart, engine: "fluidAudio", chunkDurationMinutes: 1,
                                            chunks: [chunk]), directory: dir)
    }

    /// 94 / 120: a relaunch that finds a FINALIZED session's recovery file cleans its leftovers (R2's
    /// `cleanupFinalized`) and does nothing else — no second finalize, no rename panel, no STOPPED row.
    @Test func aFinalizedSessionWithLeftoversIsCleanedUpSilently() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try slotSentinel(h, alive: 3600, boot: "another-boot")
        let transcript = try await finalizedWithLeftovers(h, s)
        let before = try Data(contentsOf: transcript)
        await h.coordinator.recoverAtLaunch()
        #expect(h.presented.value.isEmpty, "no rename panel, no auto-summary")
        // Only its record is built (L review 200), without draining — its transcript is never finalized again.
        #expect(h.client.finalizeCalls.map(\.sessionId) == ["sess"] && h.client.drains.isEmpty, "nothing finalized again")
        #expect(h.appState.activeAlarms[.recordingStopped] == nil, "no STOPPED row for a finished recording")
        #expect(try Data(contentsOf: transcript) == before, "the transcript is untouched")
        #expect(SessionState.read(directory: outDir(s), sessionId: "sess") == nil, "the leftover progress file is gone")
        #expect(FileManager.default.fileExists(atPath: outDir(s).appendingPathComponent("sess.txt").path), "the text file is re-written")
        #expect(RecordingSentinel.read(directory: h.tmp) == nil && RecordingSentinel.readPending(directory: h.tmp).isEmpty)
        #expect(h.appState.isIdle)
    }

    /// 93: a lingering sentinel within the resume window never RESUMES a finalized session.
    @Test func aFinalizedSessionIsNeverResumed() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try slotSentinel(h, alive: 20)
        _ = try await finalizedWithLeftovers(h, s)
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.startCalls.isEmpty, "never a new capture into a finished session")
        #expect(h.appState.isIdle && h.presented.value.isEmpty)
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
    }

    /// 93b: a finalized session whose transcript cannot be read back is REBUILT from its session.json, never
    /// dropped on the marker's word; the damaged file is kept.
    @Test func aFinalizedSessionWithADamagedTranscriptIsRebuilt() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try slotSentinel(h, alive: 3600, boot: "another-boot")
        let transcript = try await finalizedWithLeftovers(h, s)
        try Data("{ damaged".utf8).write(to: transcript)
        await h.coordinator.recoverAtLaunch()
        #expect(h.presented.value == [transcript], "rebuilt and presented")
        #expect(TranscriptAssembler.verifies(transcript))
        #expect(FileManager.default.fileExists(atPath: outDir(s).appendingPathComponent("sess.damaged.json").path))
    }

    /// 136 / 137: an in-session restart failed and its helper would not stop — it may still be writing the
    /// session (the restart's own capture). Nothing is transcribed then: the session is HELD, and once the helper
    /// lets go the retry transcribes it ONCE, the audio recorded after the failure included — never a transcript
    /// with later audio silently left out, never a second transcript, rename panel or "crashed" row.
    @Test func aHeldRestartIsTranscribedOnceWithItsLateAudio() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "mic-1")
        let rotator = try #require(h.runner.chunkRotator)
        let outDir = try #require(h.client.startCalls.first).outputDirectory
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let base = String(rotator.currentBaseName.dropLast(2))
        try Harness.headerOnlyWAV().write(to: outDir.appendingPathComponent(base + "-0.wav"))
        h.client.startError = CaptureCallTimeout(call: "start", seconds: 15)
        h.coordinator.helperStopDeadline = .milliseconds(100)
        h.client.onStop = { try? await Task.sleep(for: .seconds(2)) }
        await h.coordinator.handleXPCCrash()
        #expect(RecordingSentinel.readPending(directory: h.tmp).count == 1, "held")
        #expect(RecordingSentinel.readPending(directory: h.tmp).first?.heldReason == .restartFailed, "why it is held travels with it (L review 177)")
        #expect(h.client.finalizeCalls.isEmpty && h.appState.lastJsonPath == nil, "nothing transcribed while the helper may still write")
        #expect(h.criticals.value.last?.body.contains("once the capture helper lets go") == true, "\(h.criticals.value)")
        // The helper went on writing the restart's chunk after the failure; then it lets go.
        try Harness.headerOnlyWAV().write(to: outDir.appendingPathComponent(base + "-1.wav"))
        h.appState.acknowledge(.recordingStopped)
        h.client.onStop = nil
        h.coordinator.helperStopDeadline = .seconds(5)
        await h.coordinator.retryPendingSessions()
        #expect(RecordingSentinel.readPending(directory: h.tmp).isEmpty, "finished")
        #expect(h.presented.value.count == 1 && h.client.finalizeCalls.count == 1, "one transcript, once")
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("The 2 chunks recorded before it were transcribed"), "chunk 0 and the late chunk 1: \(row)")
        // L review 177: Parley never crashed — the capture failed, and Parley waited for the helper.
        #expect(!row.contains("crashed"), "no \"crashed\" row: \(row)")
        #expect(row.contains("its capture failed and could not be restarted") && row.contains("until the capture helper let go"), "\(row)")
    }

    /// L review 137: a finalized session whose folder holds audio written AFTER its transcript, which the
    /// transcript does not list, is never silent — a row, and a note in the record.
    @Test func audioRecordedAfterTheTranscriptIsNeverSilent() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try slotSentinel(h, alive: 3600, boot: "another-boot")
        let transcript = try await finalizedWithLeftovers(h, s)
        let late = outDir(s).appendingPathComponent("sess-7.wav")
        try RecoveryFixtures.writeFakeWav(at: late, seconds: 120)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: late.path)
        await h.coordinator.recoverAtLaunch()
        #expect(h.presented.value.isEmpty && h.client.drains.isEmpty, "the transcript itself is left as it is (its record is only built, L review 200)")
        let row = try #require(h.appState.activeAlarms[.audioAfterTranscript]?.message, "its own kind (L review 219)")
        #expect(row.contains("recorded after") && row.contains("not transcribed") && row.contains("2 min"), "\(row)")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: transcript)) as? [String: Any])
        let note = (json["metadata"] as? [String: Any])?["audio_after_transcript"] as? [String: Any]
        #expect((note?["files"] as? [String]) == ["sess-7.wav"], "\(String(describing: note))")
    }

    /// 69 (R2 follow-up 1): a stale-boot salvage names the restart, never a crash.
    @Test func aStaleBootSalvageNamesTheRestartNotACrash() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try slotSentinel(h, alive: 3600, boot: "another-boot")
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        await h.coordinator.recoverAtLaunch()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("your Mac restarted during the recording") && !row.contains("crashed"), "\(row)")
        #expect(row.contains("Parley recovered 1 chunk to sess.json"), "\(row)")
    }

    /// 93 (R2 item 9): a salvaged chunk whose speech recognition failed is never called "transcribed".
    @Test func aSalvageSaysWhichChunksWereNotRecognised() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try slotSentinel(h, alive: 3600, boot: BootSession.currentUUID())
        try writeSession(dir: outDir(s), meetingStart: s.startedAt, issues: [ChunkIssue(code: .asrFailed, track: nil, count: nil)])
        await h.coordinator.recoverAtLaunch()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(row.contains("written to sess.json, but speech recognition failed on it"), "\(row)")
    }

    /// … and so does the in-session salvage, from the live session's own chunks.
    @Test func anAbandonedSessionsSalvageCountsItsRecognitionFailures() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let dir = h.tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chunk = { (i: Int, issues: [ChunkIssue]) in
            ProcessedChunk(index: i, startTime: Date(), audioPath: "s-\(i).m4a", segments: [], speakerDatabase: [:], isDualStream: true, issues: issues)
        }
        let state = SessionState(sessionId: "s", meetingStart: Date(), engine: "fluidAudio", chunkDurationMinutes: 1,
                                 chunks: [chunk(0, []), chunk(1, [ChunkIssue(code: .asrFailed, track: "remote", count: nil)])])
        let outcome = await h.coordinator.salvageAbandonedSession(sessionState: state, outputDir: dir)
        #expect(outcome.recognitionFailures == .init(remoteOnly: 1))
    }
}

// MARK: - L round A: evidence survives every exit and is credited to its own session (96, 97, 98)

@MainActor
@Suite struct RecordingCoordinatorEvidenceTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }

    /// L review 96: live-log writes are queued (item 65); a termination flushes them after the helper's stop.
    @Test func aTerminationFlushesTheQueuedEvidenceAfterTheStop() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let client = h.client, afterStop = Harness.Box(false)
        client.onFlush = { afterStop.value = client.stopCalls == 1 }
        await h.coordinator.prepareForTermination(bound: .seconds(2))
        #expect(h.client.flushCalls == 1 && afterStop.value)
    }

    /// … a user's Quit too, and a flush that hangs is bounded (1 s at most; shortened here).
    @Test func aQuitFlushesTheEvidenceWithinItsBound() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        h.coordinator.evidenceFlushBound = .milliseconds(100)
        h.client.onFlush = { try? await Task.sleep(for: .seconds(3)) }
        let began = ContinuousClock.now
        #expect(await h.coordinator.prepareForQuit(confirm: { true }))
        #expect(h.client.flushCalls == 1)
        #expect(ContinuousClock.now - began < .seconds(2), "the hung flush is bounded")
    }

    /// L review 97: the live log is committed only once the transcript is on disk: a crash while it is written
    /// is salvaged with all of its evidence.
    @Test func theEvidenceIsCommittedOnlyOnceTheTranscriptExists() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let call = try #require(h.client.startCalls.first)
        try FileManager.default.createDirectory(at: call.outputDirectory, withIntermediateDirectories: true)
        let sys = call.outputDirectory.appendingPathComponent(call.baseName + ".wav")
        try Harness.headerOnlyWAV().write(to: sys)
        h.client.stopResult = AudioPaths(systemAudio: sys, micAudio: call.outputDirectory.appendingPathComponent(call.baseName + "_mic.wav"))
        let transcriptThere = Harness.Box(false)
        h.client.onCommit = { id, dir in transcriptThere.value = FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).json").path) }
        await h.coordinator.stopRecording()
        #expect(h.client.commitCalls == [call.sessionId] && transcriptThere.value)
        #expect(h.client.evidenceOrder.suffix(2) == ["finalize:\(call.sessionId)", "commit:\(call.sessionId)"])
    }

    /// … and a transcript that could not be written commits nothing: the live log stays for the next salvage.
    @Test func aTranscriptThatCannotBeWrittenCommitsNothing() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let call = try #require(h.client.startCalls.first)
        try FileManager.default.createDirectory(at: call.outputDirectory, withIntermediateDirectories: true)
        let sys = call.outputDirectory.appendingPathComponent(call.baseName + ".wav")
        try Harness.headerOnlyWAV().write(to: sys)
        h.client.stopResult = AudioPaths(systemAudio: sys, micAudio: call.outputDirectory.appendingPathComponent(call.baseName + "_mic.wav"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: call.outputDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: call.outputDirectory.path) }
        await h.coordinator.stopRecording()
        #expect(!h.client.finalizeCalls.isEmpty, "the record was built")
        #expect(h.client.commitCalls.isEmpty, "never committed without a transcript")
    }

    /// L review 98: a pending retry drains the stray helper it stopped ONCE, attributed by helper session,
    /// before any salvage; each salvage then binds its own session before its drain and build.
    @Test func aPendingRetryAttributesTheStraysEventsBeforeAnySalvage() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        var sessions: [RecordingSentinel] = []
        for name in ["p", "h"] {
            let dir = h.tmp.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: name, meetingStart: Date(), chunkIndices: [0])
            sessions.append(RecordingSentinel(startedAt: Date(), sessionName: name, systemAudioPath: dir.appendingPathComponent("\(name)-0.wav").path,
                                              micAudioPath: dir.appendingPathComponent("\(name)-0_mic.wav").path, segment: 1, chunkIndex: 0, stopping: true))
        }
        try RecordingSentinel.writePending(sessions, directory: h.tmp)
        await h.coordinator.retryPendingSessions()
        #expect(h.client.evidenceOrder == ["attribute:p,h", "adopt:p", "finalize:p", "commit:p", "adopt:h", "finalize:h", "commit:h"])
    }
}

// MARK: - L round A: a DarkWake never swallows the real wake; one Quit deadline (104, 105)

@MainActor
@Suite struct RecordingCoordinatorWakeAndQuitTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }

    private func recording(_ h: Harness, clock: ManualTestClock) async throws {
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        h.coordinator.wakeWatchdogClock = clock
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        try FileManager.default.createDirectory(at: try #require(h.client.startCalls.first).outputDirectory, withIntermediateDirectories: true)
    }

    /// L review 104(a): the watchdog stood in for a wake that had not come (a DarkWake it took for one). The REAL
    /// didWake later, with no sleep in between, records the rest of the sleep as a gap and redoes the rotation
    /// and the banner — never swallowed.
    @Test func aRealWakeAfterTheWatchdogStoodInRecordsTheRestOfTheSleep() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let clock = ManualTestClock()
        try await recording(h, clock: clock)
        let slept = Date().addingTimeInterval(-3600)
        h.coordinator.systemWillSleep(at: slept)
        await Harness.until { clock.pendingSleeps > 0 }
        clock.advance(by: .seconds(30))
        await Harness.until { h.client.rotateCalls == 1 }
        let first = try #require(await h.runner.chunkProcessor?.getSessionState().gaps)
        #expect(first.count == 1)
        h.appState.interruptionWarning = nil
        let woke = Date()
        h.coordinator.systemDidWake(at: woke)
        await Harness.until { h.client.rotateCalls == 2 }
        #expect(h.client.rotateCalls == 2, "the real wake rotates again")
        let gaps = try #require(await h.runner.chunkProcessor?.getSessionState().gaps)
        #expect(gaps.count == 2 && gaps[1].start == gaps[0].end && gaps[1].end == woke, "the rest of the sleep is a gap too")
        #expect(h.appState.interruptionWarning == "Recording restarted — waiting for audio…")
        #expect(h.client.powerEvents == ["sleep", "wake"], "one sleep, one wake: the pairing holds")
        #expect(h.client.recordedEvents.filter { $0.kind == .systemWake }.count == 2)
    }

    /// L review 104(b): awake time with the display asleep (a DarkWake, a Power Nap) is not the lost wake: the
    /// watchdog re-arms, and fires once the Mac is fully awake.
    @Test func theWatchdogWaitsOutADarkWake() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let clock = ManualTestClock()
        try await recording(h, clock: clock)
        let displayOn = Harness.Box(false)
        h.coordinator.displayIsAwake = { displayOn.value }
        h.coordinator.systemWillSleep(at: Date())
        await Harness.until { clock.pendingSleeps > 0 }
        clock.advance(by: .seconds(30))
        await Harness.until { clock.pendingSleeps > 0 }   // re-armed
        for _ in 0..<50 { await Task.yield() }
        #expect(h.client.powerEvents == ["sleep"], "dark: no implicit wake")
        displayOn.value = true
        clock.advance(by: .seconds(30))
        await Harness.until { h.client.powerEvents.count == 2 }
        #expect(h.client.powerEvents == ["sleep", "wake"])
    }

    /// … bounded as the helper is: 5 min after the first dark sign, it wakes anyway.
    @Test func aDarkWakeThatNeverEndsIsCappedAtFiveMinutes() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let clock = ManualTestClock()
        try await recording(h, clock: clock)
        h.coordinator.displayIsAwake = { false }
        h.coordinator.systemWillSleep(at: Date())
        for _ in 0..<10 {   // 30 s, then 9 more re-arms: 4.5 min of dark after the first
            await Harness.until { clock.pendingSleeps > 0 }
            clock.advance(by: .seconds(30))
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(h.client.powerEvents == ["sleep"], "under the cap: still waiting")
        await Harness.until { clock.pendingSleeps > 0 }
        clock.advance(by: .seconds(30))
        await Harness.until { h.client.powerEvents.count == 2 }
        #expect(h.client.powerEvents == ["sleep", "wake"], "at the cap: woken anyway")
    }

    /// L review 105: the user's Quit is ONE deadline — a hung start and the stop share `quitStopBound`, never
    /// the start's 50 s and then the stop's 30 s. A start still hung at the deadline leaves its sentinel
    /// `stopping`: the next launch salvages it, never resumes it.
    @Test func aQuitDuringAHungStartIsBoundedByOneDeadline() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        h.coordinator.quitStopBound = .milliseconds(300)
        h.client.onStartAsync = { try? await Task.sleep(for: .seconds(2)) }   // the audio system hangs
        let coordinator = h.coordinator
        let starting = Task { await coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil) }
        await Harness.until { !h.client.startCalls.isEmpty }
        let began = ContinuousClock.now
        #expect(await h.coordinator.prepareForQuit(confirm: { true }))
        #expect(ContinuousClock.now - began < .milliseconds(1500), "one bound for the start and the stop")
        #expect(RecordingSentinel.read(directory: h.tmp)?.stopping == true, "salvage-only at the next launch")
        await starting.value
    }
}

// MARK: - L round A: every relaunch step yields to a new Start; no recording-folder read on the main actor (112, 122, 129)

@MainActor
@Suite struct RecordingCoordinatorYieldAndFolderTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }

    private func pending(_ h: Harness) -> [RecordingSentinel] { RecordingSentinel.readPending(directory: h.tmp) }
    private func outDir(_ s: RecordingSentinel) -> URL { URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent() }

    /// A reader whose read named `label` hangs until `release` is signalled; `reached` says it began.
    private func hangingReads(_ label: String, reached: Harness.Box<Bool>, release: DispatchSemaphore) -> FolderReads {
        FolderReads(label: "rc-folder-reads-\(UUID().uuidString)", beforeEachRead: { name in
            guard name == label else { return }
            reached.value = true
            release.wait()
        })
    }

    /// L review 112: the relaunch probe — the ping, and the stop a stopping sentinel needs — counts as a start in
    /// flight (Record is disabled), and a Start that got in anyway during the stop owns the app: the session stays
    /// pending, and nothing touches the new recording.
    @Test func aStartDuringTheRelaunchStopLeavesTheNewRecordingUntouched() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        var s = try h.writeSentinel()
        s.stopping = true; s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        let coordinator = h.coordinator, client = h.client
        let busy = Harness.Box(false)
        client.onStop = {
            client.onStop = nil
            busy.value = coordinator.isStartInFlight
            await coordinator.startRecording(sessionName: "new", microphoneDeviceId: nil)
        }
        await h.coordinator.recoverAtLaunch()
        #expect(busy.value, "Record is disabled while the relaunch probes the helper")
        #expect(h.appState.isRecording && h.client.startCalls.count == 1, "the new recording runs")
        #expect(pending(h).map(\.sessionKey) == [s.sessionKey], "the session waits")
        #expect(h.client.finalizeCalls.isEmpty, "never salvaged under the new session")
        #expect(h.client.captureEndedCalls == 0, "the new recording's crash detection is never disarmed")
        #expect(!h.coordinator.isStartInFlight, "the probe is over")
    }

    /// L review 129: a Start during the salvage's folder read is untouched — no `.transcribing` forced over it, its
    /// crash detection never disarmed — and the session stays pending for the next idle.
    @Test func aStartDuringTheSalvageReadIsLeftUntouched() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-3600); s.bootSessionUUID = "another-boot"
        try RecordingSentinel.write(s, directory: h.tmp)
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        let reached = Harness.Box(false), release = DispatchSemaphore(value: 0)
        h.coordinator.folderReads = hangingReads("salvage: session folder", reached: reached, release: release)
        let coordinator = h.coordinator
        let relaunch = Task { await coordinator.recoverAtLaunch() }
        await Harness.until { reached.value }
        let starting = Task { await coordinator.startRecording(sessionName: "new", microphoneDeviceId: nil) }
        await Harness.until { coordinator.userStartInFlight }   // the start is under way (L review 165: never fixed yields)
        release.signal()
        await relaunch.value
        await starting.value
        #expect(h.appState.isRecording, "the new recording runs — never .transcribing over it")
        #expect(h.client.captureEndedCalls == 0, "its crash detection is never disarmed")
        #expect(h.client.finalizeCalls.isEmpty && h.presented.value.isEmpty)
        #expect(pending(h).map(\.sessionKey) == [s.sessionKey], "the session waits for the next idle")
    }

    /// A re-attached recording without a chunk pipeline (its setup failed): the stop and the crash restart read its
    /// folder themselves.
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

    /// L review 122: the crash restart plans its file from the folder, off the main actor and bounded. A folder that
    /// does not answer is said so — the recording ends, its recovery file is kept (salvage-only) for when the folder
    /// answers — never a restart named blind, never a frozen UI.
    @Test func aCrashRestartWhoseFolderDoesNotAnswerKeepsTheSession() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try await reattachedWithoutPipeline(h)
        let reached = Harness.Box(false), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        h.coordinator.folderReads = hangingReads("crash restart: plan", reached: reached, release: release)
        h.coordinator.folderReadDeadline = .milliseconds(150)
        h.client.isCapturingResult = false
        let began = ContinuousClock.now
        await h.coordinator.handleXPCCrash()
        #expect(ContinuousClock.now - began < .seconds(1), "bounded")
        #expect(h.client.startCalls.isEmpty, "no restart named without the folder")
        #expect(h.appState.isIdle)
        #expect(pending(h).first.map { $0.sessionKey == s.sessionKey && $0.stopping } == true, "kept, salvage-only")
        #expect(h.criticals.value.last?.body.contains("isn’t answering") == true, "\(h.criticals.value)")
    }

    /// … and the stop's own fallback (no pipeline) reads the folder the same way: a folder that does not answer
    /// keeps the session for later, and never says "no recorded audio".
    @Test func aStopWhoseFolderDoesNotAnswerKeepsTheSession() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try await reattachedWithoutPipeline(h)
        let reached = Harness.Box(false), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        h.coordinator.folderReads = hangingReads("stop: session folder", reached: reached, release: release)
        h.coordinator.folderReadDeadline = .milliseconds(150)
        h.client.stopResult = AudioPaths(systemAudio: outDir(s).appendingPathComponent("sess-1.wav"),
                                         micAudio: outDir(s).appendingPathComponent("sess-1_mic.wav"))
        await h.coordinator.stopRecording()
        #expect(h.appState.isIdle)
        #expect(pending(h).first.map { $0.sessionKey == s.sessionKey && $0.stopping } == true, "kept for when the folder answers")
        let body = try #require(h.criticals.value.last?.body)
        #expect(body.contains("isn’t answering") && !body.contains("no recorded audio"), "\(body)")
    }
}

// MARK: - L round B: evidence keys and pins (100, 101)

@MainActor
@Suite struct RecordingCoordinatorEvidenceKeyTests {
    /// L review 101: the legacy single-file stop keys its record by the session id WITHOUT its `-N` segment — the
    /// id the evidence is bound to — never a second, unbound id for the same recording.
    @Test func theLegacyStopKeysTheRecordByTheBoundId() async throws {
        let h = try Harness()
        defer {
            h.runner.stopChunkRotation(); h.runner.teardownChunkedPipeline()
            try? FileManager.default.removeItem(at: h.tmp)
        }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.isCapturingResult = true
        h.runner.failSetupForTesting = true   // re-attached without a pipeline: the stop's fallback runs
        await h.coordinator.recoverAtLaunch()
        let dir = URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent()
        h.client.stopResult = AudioPaths(systemAudio: dir.appendingPathComponent("sess-3.wav"), micAudio: dir.appendingPathComponent("sess-3_mic.wav"))
        await h.coordinator.stopRecording()
        #expect(h.client.finalizeCalls.first?.sessionId == "sess", "\(h.client.finalizeCalls.map(\.sessionId))")
    }
}

// MARK: - L round B: quits, terminations and sleep (111, 117, 138)

@MainActor
@Suite struct RecordingCoordinatorQuitRoundBTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }

    /// L review 117: §8.5's "60 s of confirmed frames" runs on AWAKE time — a sleep inside the window never
    /// shortens it. The window's clock is injectable; the streak resets exactly when it has run out.
    @Test func theConfirmationWindowCountsAwakeTime() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try h.writeSentinel()
        h.appState.phase = .recording(since: Date())
        let clock = ManualTestClock()
        h.coordinator.recoveryConfirmationClock = clock
        h.coordinator.recoveryConfirmationSeconds = 60
        await h.coordinator.handleXPCCrash()
        #expect(h.coordinator.xpcRetryCount == 1)
        h.coordinator.noteFirstFrames(track: .mic, helperSessionId: "2000-0")
        await Harness.until { clock.pendingSleeps > 0 }
        clock.advance(by: .seconds(59))
        for _ in 0..<50 { await Task.yield() }
        #expect(h.coordinator.xpcRetryCount == 1, "59 s awake: not yet")
        clock.advance(by: .seconds(1))
        await Harness.until { h.coordinator.xpcRetryCount == 0 }
        #expect(h.coordinator.xpcRetryCount == 0, "60 s awake: confirmed")
    }

    /// L review 138: a Quit during the launch's brief probe of a previous recording is not a Quit during a start —
    /// nothing is asked, and nothing is stopped: the next launch probes again.
    @Test func aQuitDuringTheLaunchProbeAsksNothing() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID()
        try RecordingSentinel.write(s, directory: h.tmp)
        let coordinator = h.coordinator
        let answered = Harness.Box<Bool?>(nil)
        h.client.onIsCapturing = {
            #expect(coordinator.isStartInFlight, "Record is disabled while probing (L review 112)")
            answered.value = await coordinator.prepareForQuit(confirm: { Issue.record("nothing to confirm during the probe"); return false })
        }
        await h.coordinator.recoverAtLaunch()
        #expect(answered.value == true)
    }
}

// MARK: - L round B: rotation and the retry after a hold (113, 118)

@MainActor
@Suite struct RecordingCoordinatorRotationRoundBTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }
    private func pending(_ h: Harness) -> [RecordingSentinel] { RecordingSentinel.readPending(directory: h.tmp) }

    /// L review 113: at Stop, the helper's reply names the chunk it sealed. With no late attempt on record, a reply
    /// naming chunk 1 while the rotator still names chunk 0 labels that audio 1 — and chunk 0 goes from its own files.
    @Test func theStopsReplyNamesTheLastChunk() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let rotator = try #require(h.runner.chunkRotator)
        let outDir = try #require(h.client.startCalls.first).outputDirectory
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let base = String(rotator.currentBaseName.dropLast(2))
        for name in [base + "-0", base + "-1"] {
            for suffix in [".wav", "_mic.wav"] { try Harness.headerOnlyWAV().write(to: outDir.appendingPathComponent(name + suffix)) }
        }
        h.client.stopResult = AudioPaths(systemAudio: outDir.appendingPathComponent(base + "-1.wav"),
                                         micAudio: outDir.appendingPathComponent(base + "-1_mic.wav"))
        let runner = h.runner
        let chunks = Harness.Box<[ProcessedChunk]>([])
        h.client.onFinalizeDiagnostics = { chunks.value = await runner.chunkProcessor?.getSessionState().chunks ?? [] }
        await h.coordinator.stopRecording()
        #expect(chunks.value.map(\.index).sorted() == [0, 1], "\(chunks.value.map(\.index))")
        for chunk in chunks.value {
            #expect(URL(fileURLWithPath: chunk.audioPath).deletingPathExtension().lastPathComponent.hasSuffix("-\(chunk.index)"), "\(chunk.audioPath)")
        }
    }

    /// L review 118: a failed restart whose helper let go, with the restart's own file on disk: that file (sealed by
    /// the stop) joins the salvage.
    @Test func aFailedRestartsOwnFileJoinsTheSalvage() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let rotator = try #require(h.runner.chunkRotator)
        let outDir = try #require(h.client.startCalls.first).outputDirectory
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let base = String(rotator.currentBaseName.dropLast(2))
        try Harness.headerOnlyWAV().write(to: outDir.appendingPathComponent(base + "-0.wav"))
        // The restart captured into chunk 1, then failed; the stop lets it go.
        h.client.onStart = { try? Harness.headerOnlyWAV().write(to: outDir.appendingPathComponent(base + "-1.wav")) }
        h.client.startError = FakeCaptureError()
        h.client.onStartAsync = nil
        h.client.stopResult = AudioPaths(systemAudio: outDir.appendingPathComponent(base + "-1.wav"),
                                         micAudio: outDir.appendingPathComponent(base + "-1_mic.wav"))
        h.coordinator.helperStopDeadline = .seconds(5)
        let runner = h.runner
        let chunks = Harness.Box<[ProcessedChunk]>([])
        h.client.onFinalizeDiagnostics = { chunks.value = await runner.chunkProcessor?.getSessionState().chunks ?? [] }
        await h.coordinator.handleXPCCrash()
        #expect(h.appState.isIdle)
        #expect(chunks.value.map(\.index).sorted() == [0, 1], "the orphan and the restart's own file: \(chunks.value.map(\.index))")
    }

    /// L review 118: the pending retry's stop that the helper does not answer — the connection is dropped, and the
    /// session stays pending: never salvaged while its file may still be written.
    @Test func aPendingRetryWhoseStopIsUnansweredKeepsTheSession() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try h.writeSentinel()
        try RecordingSentinel.writePending([s], directory: h.tmp)
        RecordingSentinel.delete(directory: h.tmp)
        h.coordinator.helperStopDeadline = .milliseconds(100)
        h.client.onStop = { try? await Task.sleep(for: .seconds(1)) }
        await h.coordinator.retryPendingSessions()
        #expect(h.client.droppedConnections == 1)
        #expect(pending(h).map(\.sessionKey) == [s.sessionKey] && h.client.finalizeCalls.isEmpty)
    }

    /// L review 118: a hold at launch (the helper would not let go of one session) does not make the OTHER pending
    /// sessions wait for another event: they are finished now — without asking the stuck helper a second time.
    @Test func aHoldDoesNotDelayTheOtherPendingSessions() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let other = h.tmp.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try RecoveryFixtures.writeSessionJSON(dir: other, sessionId: "old", meetingStart: Date(), chunkIndices: [0])
        let older = RecordingSentinel(startedAt: Date(), sessionName: "Old", systemAudioPath: other.appendingPathComponent("old-0.wav").path,
                                      micAudioPath: other.appendingPathComponent("old-0_mic.wav").path, segment: 1, chunkIndex: 0, stopping: true)
        try RecordingSentinel.writePending([older], directory: h.tmp)
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID(); s.stopping = true
        try RecordingSentinel.write(s, directory: h.tmp)
        h.client.isCapturingResult = true
        h.coordinator.helperStopDeadline = .milliseconds(100)
        h.client.onStop = { try? await Task.sleep(for: .seconds(1)) }   // the helper will not let go of `s`
        await h.coordinator.recoverAtLaunch()
        #expect(pending(h).map(\.sessionKey) == [s.sessionKey], "held; the older one finished")
        #expect(h.presented.value.count == 1 && h.presented.value.first?.lastPathComponent == "old.json")
        #expect(h.client.stopCalls == 1, "the stuck helper was asked once")
    }
}

// MARK: - L round B: relaunch and pending sessions (124, 127, 128, 130–133, 135)

@MainActor
@Suite struct RecordingCoordinatorRelaunchRoundBTests {
    private func tearDown(_ h: Harness) {
        h.runner.stopChunkRotation()
        h.runner.teardownChunkedPipeline()
        try? FileManager.default.removeItem(at: h.tmp)
    }
    private func pending(_ h: Harness) -> [RecordingSentinel] { RecordingSentinel.readPending(directory: h.tmp) }
    private func outDir(_ s: RecordingSentinel) -> URL { URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent() }
    private func fresh(_ h: Harness, stopping: Bool = false) throws -> RecordingSentinel {
        var s = try h.writeSentinel()
        s.lastAliveAt = Date().addingTimeInterval(-5); s.bootSessionUUID = BootSession.currentUUID(); s.stopping = stopping
        try RecordingSentinel.write(s, directory: h.tmp)
        return s
    }
    private func reads(_ onRead: @escaping @Sendable (String) -> Void) -> FolderReads {
        FolderReads(label: "rc-relaunch-b-\(UUID().uuidString)", beforeEachRead: onRead)
    }

    /// L review 124: a crash reported while Flow A reads its folder (the phase still idle) is not swallowed — it is
    /// queued, and recovered once the recording is re-attached.
    @Test func aCrashDuringTheReattachScanIsRecovered() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        _ = try fresh(h)
        h.client.isCapturingResult = true
        let client = h.client
        let crashed = Harness.Box(false)
        h.coordinator.folderReads = reads { label in
            guard label == "re-attach: session folder", !crashed.value else { return }
            crashed.value = true
            DispatchQueue.main.sync { MainActor.assumeIsolated { client.isCapturingResult = false; client.onServiceCrash?() } }
        }
        await h.coordinator.recoverAtLaunch()
        await Harness.until { h.client.startCalls.count == 1 }
        #expect(crashed.value && h.client.startCalls.count == 1, "the crash in the scan's window was recovered: a restart")
        #expect(h.appState.isRecording)
    }

    /// L review 127: a resume whose folder scan timed out keeps the session pending AND its folder alarm, even
    /// when the next read of the folder answers — never silent until the next event.
    @Test func aResumeScanThatTimedOutKeepsItsAlarm() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try fresh(h)
        // Another pending session, elsewhere: the alarm's read of the pending folders is then not the scan's folder
        // alone — it answers, once the slow scan has let the queue go.
        let other = h.tmp.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try RecordingSentinel.writePending([RecordingSentinel(startedAt: Date(), sessionName: "o", systemAudioPath: other.appendingPathComponent("o-0.wav").path,
                                                              micAudioPath: other.appendingPathComponent("o-0_mic.wav").path)], directory: h.tmp)
        h.coordinator.folderReadDeadline = .milliseconds(100)
        h.coordinator.folderReads = reads { label in if label == "resume: session folder" { Thread.sleep(forTimeInterval: 0.15) } }
        h.client.onStop = { try? await Task.sleep(for: .seconds(1)) }   // the other one stays pending: no salvage here
        h.coordinator.helperStopDeadline = .milliseconds(50)
        await h.coordinator.recoverAtLaunch()
        #expect(pending(h).map(\.sessionKey).contains(s.sessionKey))
        #expect(h.appState.activeAlarms[.recordingFolderUnavailable] != nil, "said until the next event resolves it")
    }

    /// L review 128: a hung relaunch read of a STOPPING session's folder waits for the folder — but first stops the
    /// helper (bounded), as a salvage would: never `captureEnded` while the helper may still be capturing.
    @Test func aStoppingSessionWaitingForItsFolderStopsTheHelperFirst() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try fresh(h, stopping: true)
        h.coordinator.folderReadDeadline = .milliseconds(100)
        h.coordinator.folderReads = reads { label in if label == "relaunch: recording folder" { Thread.sleep(forTimeInterval: 0.3) } }
        h.client.isCapturingResult = true
        await h.coordinator.recoverAtLaunch()
        #expect(h.client.stopCalls == 1, "stopped before waiting")
        #expect(pending(h).map(\.sessionKey) == [s.sessionKey])
    }

    /// L review 128: a relaunch whose folder is reached through a DANGLING link to an absent volume waits for it.
    @Test func aRelaunchThroughADanglingLinkWaits() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let link = h.tmp.appendingPathComponent("Recordings")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Volumes/Absent-\(UUID().uuidString)/Recordings")
        let dir = link.appendingPathComponent("day")
        let s = RecordingSentinel(startedAt: Date(), sessionName: "T", systemAudioPath: dir.appendingPathComponent("sess-0.wav").path,
                                  micAudioPath: dir.appendingPathComponent("sess-0_mic.wav").path, segment: 1, chunkIndex: 0,
                                  lastAliveAt: Date().addingTimeInterval(-5), bootSessionUUID: BootSession.currentUUID())
        try RecordingSentinel.write(s, directory: h.tmp)
        await h.coordinator.recoverAtLaunch()
        #expect(pending(h).map(\.sessionKey) == [s.sessionKey] && h.client.startCalls.isEmpty && h.client.finalizeCalls.isEmpty)
        #expect(h.appState.activeAlarms[.recordingFolderUnavailable]?.message.contains("isn’t reachable") == true)
    }

    /// L review 128: the folder alarm's not-writable wording, for a pending session whose folder is read-only.
    @Test func aReadOnlyPendingFolderIsWordedAsPermissions() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try h.writeSentinel()
        try RecordingSentinel.writePending([s], directory: h.tmp)
        RecordingSentinel.delete(directory: h.tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: outDir(s).path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outDir(s).path) }
        await h.coordinator.retryPendingSessions()
        #expect(h.appState.activeAlarms[.recordingFolderUnavailable]?.message.contains("check its permissions") == true)
    }

    /// L review 130: a pending list that is there but cannot be READ (permissions, I/O) is set aside like one that
    /// cannot be decoded — never read as empty and then overwritten.
    @Test func anUnreadablePendingFileIsSetAsideNeverOverwritten() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let file = h.tmp.appendingPathComponent("pending-sessions.json")
        try Data("[]".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        let loaded = RecordingSentinel.loadPending(directory: h.tmp)
        #expect(loaded.setAside != nil && !FileManager.default.fileExists(atPath: file.path), "moved aside")
    }

    /// … and when it cannot even be moved aside, the row says it was LEFT in place (never "set aside"), once per
    /// pass, and nothing overwrites it.
    @Test func anUnreadablePendingFileThatCannotBeMovedIsKeptAndSaidOnce() async throws {
        let h = try Harness()
        let sentinels = h.tmp.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: sentinels, withIntermediateDirectories: true)
        let file = sentinels.appendingPathComponent("pending-sessions.json")
        try Data("not a list".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sentinels.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sentinels.path)
            try? FileManager.default.removeItem(at: h.tmp)
        }
        let loaded = RecordingSentinel.loadPending(directory: sentinels)
        #expect(loaded.setAside == nil && loaded.keptUnreadable == file)
        #expect(throws: (any Error).self, "never overwritten") {
            try RecordingSentinel.writePending([RecordingSentinel(startedAt: Date(), sessionName: "x", systemAudioPath: "/x/y-0.wav",
                                                                  micAudioPath: "/x/y-0_mic.wav")], directory: sentinels)
        }
        #expect(try Data(contentsOf: file) == Data("not a list".utf8))
    }

    /// L review 131: the recovery gate starts HELD until launch recovery runs — a wake or a mount retry never beats
    /// it to a crashed app's live helper — and the deferred retry runs once it is released (L review 135).
    @Test func theGateStartsHeldUntilLaunchRecovery() async throws {
        let h = try Harness(launchRecoveryPending: true)
        defer { tearDown(h) }
        let s = try h.writeSentinel()
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        var p = s; p.stopping = true
        try RecordingSentinel.writePending([p], directory: h.tmp)
        RecordingSentinel.delete(directory: h.tmp)
        await h.coordinator.retryPendingSessions()   // a mount before launch recovery
        #expect(h.client.stopCalls == 0 && pending(h).count == 1, "deferred: launch recovery goes first")
        await h.coordinator.recoverAtLaunch()
        #expect(pending(h).isEmpty && h.presented.value.count == 1, "run by launch recovery")
    }

    /// L review 135: a retry asked for DURING launch recovery runs once the gate frees.
    @Test func aRetryDeferredDuringLaunchRecoveryRunsWhenTheGateFrees() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try fresh(h, stopping: true)   // salvaged at launch
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        let other = h.tmp.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try RecoveryFixtures.writeSessionJSON(dir: other, sessionId: "old", meetingStart: Date(), chunkIndices: [0])
        let coordinator = h.coordinator
        let asked = Harness.Box(false)
        h.client.onIsCapturing = {
            guard !asked.value else { return }
            asked.value = true
            // A mount during the probe: its session arrives now, and its retry is deferred.
            try? RecordingSentinel.writePending([RecordingSentinel(
                startedAt: Date(), sessionName: "Old", systemAudioPath: other.appendingPathComponent("old-0.wav").path,
                micAudioPath: other.appendingPathComponent("old-0_mic.wav").path, segment: 1, chunkIndex: 0, stopping: true)], directory: h.tmp)
            await coordinator.retryPendingSessions()
        }
        await h.coordinator.recoverAtLaunch()
        await Harness.until { pending(h).isEmpty }
        #expect(pending(h).isEmpty, "the deferred retry ran once the gate freed")
        #expect(h.presented.value.count == 2)
    }

    /// L review 135: a session in BOTH the slot and the list is cleared from both by its salvage.
    @Test func aSlotPlusListSalvageClearsBoth() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        let s = try fresh(h, stopping: true)
        try RecoveryFixtures.writeSessionJSON(dir: outDir(s), sessionId: "sess", meetingStart: s.startedAt, chunkIndices: [0])
        try RecordingSentinel.writePending([s], directory: h.tmp)
        await h.coordinator.recoverAtLaunch()
        #expect(RecordingSentinel.read(directory: h.tmp) == nil && pending(h).isEmpty)
        #expect(h.presented.value.count == 1, "salvaged once")
    }

    /// L review 132: a failed start whose helper will not let go, with no readable slot sentinel, is still held —
    /// from what the start wrote — with a row, so the mic it marked is released once the helper lets go.
    @Test func aFailedStartWithoutASlotSentinelIsStillHeld() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        h.client.startError = CaptureCallTimeout(call: "start", seconds: 15)
        h.coordinator.helperStopDeadline = .milliseconds(100)
        let tmp = h.tmp
        h.client.onStop = { RecordingSentinel.delete(directory: tmp); try? await Task.sleep(for: .seconds(1)) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: "mic-9")
        #expect(pending(h).count == 1 && pending(h).first?.stopping == true, "held from the start's own copy")
        #expect(h.appState.activeAlarms[.recordingStopped] != nil, "said")
        #expect(h.recordingMic.current == .some("mic-9"), "marked while the helper may hold it")
        h.client.onStop = nil
        await h.coordinator.retryPendingSessions()
        #expect(h.recordingMic.current == nil, "released once the helper let go")
    }

    /// L review 133: "N earlier recordings were recovered" counts only the ones that were — a salvage with nothing to
    /// transcribe is said on its own.
    @Test func onlyRealRecoveriesAreCounted() async throws {
        let h = try Harness()
        defer { tearDown(h) }
        var sessions: [RecordingSentinel] = []
        for name in ["one", "two"] {
            let dir = h.tmp.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if name == "one" { try RecoveryFixtures.writeSessionJSON(dir: dir, sessionId: name, meetingStart: Date(), chunkIndices: [0]) }
            sessions.append(RecordingSentinel(startedAt: Date(), sessionName: name, systemAudioPath: dir.appendingPathComponent("\(name)-0.wav").path,
                                              micAudioPath: dir.appendingPathComponent("\(name)-0_mic.wav").path, segment: 1, chunkIndex: 0, stopping: true))
        }
        try RecordingSentinel.writePending(sessions, directory: h.tmp)
        await h.coordinator.retryPendingSessions()
        let row = try #require(h.appState.activeAlarms[.recordingStopped]?.message)
        #expect(!row.contains("earlier recordings were recovered"), "one was, one had nothing: \(row)")
        #expect(row.contains("one.json") && row.contains("no recorded audio was found"), "\(row)")
    }

    /// L review 135: the item-81 trace end to end — a failed start held, a second Start works, and once the helper
    /// lets go the held session is salvaged — never resumed.
    @Test func aHeldFailedStartIsFinishedAfterANewRecording() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { tearDown(h) }
        h.client.startError = CaptureCallTimeout(call: "start", seconds: 15)
        h.coordinator.helperStopDeadline = .milliseconds(100)
        h.client.onStop = { try? await Task.sleep(for: .seconds(1)) }
        await h.coordinator.startRecording(sessionName: "held", microphoneDeviceId: nil)
        let held = try #require(pending(h).first)
        h.client.startError = nil
        h.client.onStop = nil
        await h.coordinator.startRecording(sessionName: "next", microphoneDeviceId: nil)
        #expect(h.appState.isRecording && pending(h).map(\.sessionKey) == [held.sessionKey], "the held session waits")
        try FileManager.default.createDirectory(at: outDir(held), withIntermediateDirectories: true)
        let call = try #require(h.client.startCalls.last)
        h.client.stopResult = AudioPaths(systemAudio: call.outputDirectory.appendingPathComponent(call.baseName + ".wav"),
                                         micAudio: call.outputDirectory.appendingPathComponent(call.baseName + "_mic.wav"))
        h.client.stopError = FakeCaptureError()   // the second recording's stop fails: salvaged; the held one is next
        await h.coordinator.stopRecording()
        h.client.stopError = nil
        h.client.stopResult = nil
        await h.coordinator.retryPendingSessions()
        #expect(pending(h).isEmpty, "salvaged once the helper let go")
        #expect(h.client.startCalls.filter { $0.sessionId == stripSegmentSuffix(held.systemAudioPath) }.count == 1, "never resumed")
    }
}
