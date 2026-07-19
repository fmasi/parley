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
    /// Spy on provenance finalization: which session the orchestration stamped, and where.
    var finalizeCalls: [(sessionId: String, engine: String, recordingDirectory: URL)] = []

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
        finalizeCalls.append((sessionId, engine, recordingDirectory))
        return CaptureDiagnostics().makeProvenance(
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
    let runner = TranscriptionRunner()
    let config: ConfigManager
    let coordinator: RecordingCoordinator
    let notified: Box<[(title: String, body: String)]> = Box([])
    let criticals: Box<[(title: String, body: String)]> = Box([])
    let presented: Box<[URL]> = Box([])

    final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

    init() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        config = ConfigManager(configDir: tmp)  // empty dir -> Config.default
        let notified = notified
        let criticals = criticals
        let presented = presented
        coordinator = RecordingCoordinator(
            appState: appState,
            captureClient: client,
            transcriptionRunner: runner,
            configManager: config,
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

    // NOTE: tests ESCALATION only (no live pipeline here, so the salvage attempt is a no-op).
    // The salvage path itself is covered by RecordingCoordinatorSalvageTests.
    @Test func crashRestartFailureEscalatesCritically() async throws {
        let h = try Harness()
        _ = try h.writeSentinel()
        h.client.startError = FakeCaptureError()

        await h.coordinator.handleXPCCrash()

        #expect(h.appState.criticalError?.contains("could not restart capture") == true)
        #expect(h.appState.isIdle)
        #expect(RecordingSentinel.read(directory: h.tmp) == nil)
        #expect(h.criticals.value.map { $0.title } == ["Recording Failed"])
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

        await h.coordinator.salvageAbandonedSession(
            sessionState: state, outputDir: h.tmp.appendingPathComponent("out")
        )

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

        await h.coordinator.salvageAbandonedSession(sessionState: state, outputDir: outDir)

        // The salvage path drains diagnostics and stamps provenance for THIS session before
        // finalizing (the whole point of council F3 + #95).
        let first = try #require(h.client.finalizeCalls.first)
        #expect(first.sessionId == "sess")
        #expect(first.recordingDirectory == outDir)
    }
}
