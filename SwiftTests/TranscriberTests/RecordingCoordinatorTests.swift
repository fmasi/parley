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

    struct StartCall: Equatable {
        let outputDirectory: URL
        let baseName: String
        let microphoneDeviceId: String?
        let systemAudioSource: SystemAudioSource
    }

    var startCalls: [StartCall] = []
    var startError: Error?
    var stopCalls = 0
    var stopError: Error?
    var stopResult: AudioPaths?
    var retryEvents: [[String: String]] = []

    func start(
        outputDirectory: URL,
        baseName: String,
        microphoneDeviceId: String?,
        systemAudioSource: SystemAudioSource
    ) async throws {
        startCalls.append(StartCall(
            outputDirectory: outputDirectory,
            baseName: baseName,
            microphoneDeviceId: microphoneDeviceId,
            systemAudioSource: systemAudioSource
        ))
        if let startError { throw startError }
    }

    func stop() async throws -> AudioPaths {
        stopCalls += 1
        if let stopError { throw stopError }
        guard let stopResult else { throw CocoaError(.fileNoSuchFile) }
        return stopResult
    }

    func finalizeSessionDiagnostics(
        sessionId: String, engine: String, recordingDirectory: URL
    ) async -> CaptureProvenance {
        CaptureDiagnostics().makeProvenance(
            engine: engine, systemFormat: nil, micFormat: nil, micDevice: nil
        )
    }

    func recordRetry(_ detail: [String: String]) {
        retryEvents.append(detail)
    }

    func rotateChunk(outputDirectory: String, newBaseName: String) async throws
        -> (systemPath: String, micPath: String) {
        (outputDirectory + "/" + newBaseName + ".wav",
         outputDirectory + "/" + newBaseName + "_mic.wav")
    }
}

private struct FakeCaptureError: Error, LocalizedError {
    var errorDescription: String? { "fake capture failure" }
}

@MainActor
private struct Harness {
    let tmp: URL
    let appState = AppState()
    let client = FakeCaptureClient()
    let coordinator: RecordingCoordinator
    let notified: Box<[(title: String, body: String)]> = Box([])
    let criticals: Box<[(title: String, body: String)]> = Box([])
    let presented: Box<[URL]> = Box([])

    final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

    init() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let notified = notified
        let criticals = criticals
        let presented = presented
        coordinator = RecordingCoordinator(
            appState: appState,
            captureClient: client,
            transcriptionRunner: TranscriptionRunner(),
            configManager: ConfigManager(configDir: tmp),  // empty dir -> Config.default
            sentinelDirectory: tmp,
            notify: { notified.value.append(($0, $1)) },
            notifyCritical: { criticals.value.append(($0, $1)) },
            presentTranscript: { url, _ in presented.value.append(url) }
        )
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
        // The crash/fatal/mic-change callbacks are wired before start is attempted.
        #expect(h.client.onServiceCrash != nil)
        #expect(h.client.onFatalFailure != nil)
        #expect(h.client.onMicDeviceChanged != nil)
        // Sentinel was written before start (then deleted on failure); start saw the -0 base name.
        #expect(h.client.startCalls.count == 1)
        #expect(h.client.startCalls[0].baseName.hasSuffix("-Test-0"))
        #expect(h.client.startCalls[0].microphoneDeviceId == "mic-1")
    }

    @Test func crashWithoutSentinelEscalatesCritically() async throws {
        let h = try Harness()

        await h.coordinator.handleXPCCrash()

        #expect(h.appState.criticalError == "Recording failed — no recovery data available.")
        #expect(h.appState.isIdle)
        #expect(h.criticals.value.map { $0.title } == ["Recording Failed"])
        #expect(h.client.startCalls.isEmpty)
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

        let rewritten = try #require(RecordingSentinel.read(directory: h.tmp))
        #expect(rewritten.segment == sentinel.segment + 1)
        #expect(rewritten.chunkIndex == 1)  // stamped directly (#154 finding 6)
        #expect(rewritten.systemAudioPath.hasSuffix("sess-1.wav"))
        #expect(rewritten.micAudioPath.hasSuffix("sess-1_mic.wav"))

        #expect(h.appState.interruptionWarning == "Recording briefly interrupted. Resuming.")
        #expect(h.notified.value.map { $0.title } == ["Recording Resumed"])
        #expect(h.coordinator.xpcRetryCount == 0)  // streak reset after a successful restart
        #expect(h.coordinator.recoveryInFlight == false)
    }

    @Test func crashRestartFailureSalvagesAndEscalates() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.client.startError = FakeCaptureError()

        await h.coordinator.handleXPCCrash()

        #expect(h.appState.criticalError?.contains("could not restart capture") == true)
        #expect(h.appState.isIdle)
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
        #expect(h.criticals.value.map { $0.title } == ["Recording Failed"])
    }

    @Test func crashLoopWithinDecayWindowGivesUp() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        // Seed an exhausted streak: the next crash inside the decay window exceeds maxRetries.
        h.coordinator.xpcRetryCount = XPCRetryPolicy.defaultMaxRetries
        h.coordinator.lastCrashAt = Date()

        await h.coordinator.handleXPCCrash()

        #expect(h.client.startCalls.isEmpty)  // no restart attempt after give-up
        #expect(h.appState.criticalError?.contains("crashed repeatedly") == true)
        #expect(h.appState.isIdle)
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
        #expect(h.criticals.value.map { $0.title } == ["Recording Failed"])
        #expect(h.client.retryEvents == [["attempt": "3", "giveUp": "true"]])
    }

    @Test func crashAfterDecayIntervalStartsAFreshStreak() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        // #61: the streak decays — an old exhausted streak must NOT trip the cap.
        h.coordinator.xpcRetryCount = XPCRetryPolicy.defaultMaxRetries
        h.coordinator.lastCrashAt = Date().addingTimeInterval(-(XPCRetryPolicy.defaultDecayInterval + 1))

        await h.coordinator.handleXPCCrash()

        #expect(h.client.startCalls.count == 1)  // restarted instead of giving up
        #expect(h.appState.criticalError == nil)
        #expect(h.notified.value.map { $0.title } == ["Recording Resumed"])
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
}
