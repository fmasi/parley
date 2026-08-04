import Foundation
import Observation
import os

/// Owns the recording lifecycle + crash-recovery orchestration that used to live inside
/// `MenuView` (#139 audit finding 3): start/stop, the XPC-crash retry/restart state machine,
/// and salvage of abandoned chunked sessions. A plain `@MainActor` object — not a SwiftUI view —
/// so this logic is finally reachable from the unit-test suite (with a fake
/// `RecordingCaptureClient`). `MenuView` keeps presentation only and delegates here.
///
/// UI side effects the app target owns (user notifications, the critical-alert panel, the
/// rename dialog + auto-summary) are injected as closures, so the orchestration itself has no
/// AppKit/UserNotifications dependency.
@MainActor
@Observable
public final class RecordingCoordinator {
    private let appState: AppState
    private let captureClient: any RecordingCaptureClient
    private let transcriptionRunner: TranscriptionRunner
    private let configManager: ConfigManager
    /// Test-only override for where the crash sentinel lives; nil = the real app-support path.
    private let sentinelDirectory: URL?
    /// Post a normal user notification: (title, body).
    private let notify: @MainActor (String, String) -> Void
    /// Post a critical alert (floating panel + critical notification): (title, body).
    private let notifyCritical: @MainActor (String, String) -> Void
    /// Present a completed transcript — rename dialog, then auto-summary: (jsonPath, config).
    private let presentTranscript: @MainActor (URL, Config) -> Void

    // MARK: - Lifecycle state (previously `@State` in MenuView)

    /// Consecutive XPC-crash count within the decay window (#61). Internal for test seeding.
    var xpcRetryCount = 0
    var lastCrashAt: Date?
    /// True while handleXPCCrash is mid-recovery (across its `await start()`). A user Stop in that
    /// window must not race the helper restart (council FV2) — it sets stopRequestedDuringRecovery
    /// and the recovery handler honors it once capture is back up.
    var recoveryInFlight = false
    var stopRequestedDuringRecovery = false
    /// True once the helper has reported which device it is actually capturing on (post auto-switch).
    /// When false, `helperMicId` is meaningless and the UI falls back to the user's selection.
    public private(set) var helperMicKnown: Bool = false
    /// The mic device the helper is ACTUALLY capturing on, reported via the reverse channel after an
    /// auto-switch. Valid only when `helperMicKnown` is true. `nil` = helper on system default;
    /// non-nil = helper on this specific device. Both cleared when recording stops.
    public private(set) var helperMicId: String? = nil

    public init(
        appState: AppState,
        captureClient: any RecordingCaptureClient,
        transcriptionRunner: TranscriptionRunner,
        configManager: ConfigManager,
        sentinelDirectory: URL? = nil,
        notify: @escaping @MainActor (String, String) -> Void,
        notifyCritical: @escaping @MainActor (String, String) -> Void,
        presentTranscript: @escaping @MainActor (URL, Config) -> Void
    ) {
        self.appState = appState
        self.captureClient = captureClient
        self.transcriptionRunner = transcriptionRunner
        self.configManager = configManager
        self.sentinelDirectory = sentinelDirectory
        self.notify = notify
        self.notifyCritical = notifyCritical
        self.presentTranscript = presentTranscript
    }

    // MARK: - Pure decision helpers (unit-tested)

    /// Naming for a new recording session: the day folder, the sanitized session name, the chunked
    /// session's base name, and the first capture file's base name (`-0`, 0-indexed for chunk
    /// discovery).
    nonisolated static func startNaming(
        sessionName: String, now: Date
    ) -> (dayDir: String, sanitized: String, chunkBaseName: String, baseName: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dayDir = dateFormatter.string(from: now)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmmss"
        let timestamp = timeFormatter.string(from: now)

        let sanitized = sanitizeFilename(sessionName)
        let chunkBaseName = sanitized.isEmpty ? timestamp : "\(timestamp)-\(sanitized)"
        let baseName = "\(chunkBaseName)-0"  // 0-indexed for chunk discovery
        return (dayDir, sanitized, chunkBaseName, baseName)
    }

    /// Where the fallback (no-live-pipeline) stop looks for the session. Prefer the sentinel's
    /// recorded path — it survives an app relaunch that re-attached to a still-recording XPC
    /// service — over the path of whichever WAV the stop just returned.
    nonisolated static func fallbackSessionLocation(
        sentinel: RecordingSentinel?, stoppedSystemAudioPath: String
    ) -> (outputDir: URL, sessionId: String) {
        if let sentinel {
            return (
                URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent(),
                stripSegmentSuffix(sentinel.systemAudioPath)
            )
        }
        return (
            URL(fileURLWithPath: stoppedSystemAudioPath).deletingLastPathComponent(),
            stripSegmentSuffix(stoppedSystemAudioPath)
        )
    }

    /// Which audio files the legacy single-file transcription runs on. For a multi-segment session,
    /// #7: point discovery at the 0-indexed base so SegmentDiscovery's gap-tolerant 0-indexed mode
    /// reclaims every segment (-0, -1, …). The stripped base would use legacy mode and drop the
    /// -0 orphan, referencing a non-existent `<root>.wav`.
    nonisolated static func legacySingleFileInputs(
        sentinel: RecordingSentinel?, stoppedPaths: AudioPaths
    ) -> (systemAudio: URL, micAudio: URL?) {
        if let sentinel, sentinel.segment > 1 {
            let origBase = stripSegmentSuffix(sentinel.systemAudioPath)
            let dir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
            return (
                dir.appendingPathComponent(origBase + "-0.wav"),
                dir.appendingPathComponent(origBase + "-0_mic.wav")
            )
        }
        return (stoppedPaths.systemAudio, stoppedPaths.micAudio)
    }

    /// Pure target selection for re-ingesting the orphaned in-progress chunk after a live XPC
    /// crash: the chunk's WAV paths come from the rotator's LIVE base name — NOT the sentinel path,
    /// which is written at session start, goes stale after the first rotation, and would re-enqueue
    /// the already-processed chunk while the true orphan's audio is silently dropped (#92).
    nonisolated static func orphanChunk(
        index: Int, startTime: Date, liveBaseName: String, outputDir: URL
    ) -> ChunkRotator.FinalizedChunk {
        ChunkRotator.FinalizedChunk(
            index: index,
            systemPath: outputDir.appendingPathComponent(liveBaseName + ".wav").path,
            micPath: outputDir.appendingPathComponent(liveBaseName + "_mic.wav").path,
            startTime: startTime
        )
    }

    /// Pure restart naming for the live-pipeline crash branch: the restart capture is named by the
    /// rotator's recovery plan, and the sentinel advances one segment with the plan's chunk index
    /// stamped directly (#154 finding 6 — never left to a later disk scan).
    nonisolated static func liveRestartPlan(
        sentinel: RecordingSentinel, recoveryPlan: ChunkRecoveryPlan, outputDir: URL
    ) -> (baseName: String, newSentinel: RecordingSentinel) {
        let baseName = recoveryPlan.recoveryBaseName
        var newSentinel = sentinel.incrementedSegment(
            systemAudioPath: outputDir.appendingPathComponent(baseName + ".wav").path,
            micAudioPath: outputDir.appendingPathComponent(baseName + "_mic.wav").path
        )
        newSentinel.chunkIndex = recoveryPlan.recoveryIndex
        return (baseName, newSentinel)
    }

    // MARK: - Recording lifecycle

    public func startRecording(sessionName: String, microphoneDeviceId: String?) async {
        Logger.state.info("Recording started — session: \(sessionName, privacy: .sensitive)")
        appState.errorMessage = nil

        let config = configManager.config
        let naming = Self.startNaming(sessionName: sessionName, now: Date())

        let outputDir = URL(fileURLWithPath: config.recordingDirectory)
            .appendingPathComponent(naming.dayDir)

        // `[weak self]` replaces MenuView's old strong struct-copy capture: the coordinator retains
        // the capture client, so a strong capture here would cycle coordinator → captureClient →
        // closure → coordinator. If the coordinator were ever gone when one fires, the on-disk
        // sentinel launch recovery (TranscriberApp.recoverIfNeeded) is the backstop.
        captureClient.onServiceCrash = { [weak self] in
            Task { @MainActor in
                guard let self, self.appState.isRecording else { return }
                await self.handleXPCCrash()
            }
        }
        // #86: a benign route change no longer reads as a crash. The helper restarts the stream in
        // place (onRestartInPlace) or the connection blips without a crash report (onBriefInterruption)
        // — both keep recording silently. Only a fatal give-up escalates.
        // Routine mic switches are handled by onMicDeviceChanged (label refresh only, no banner).
        captureClient.onMicDeviceChanged = { [weak self] deviceId in
            Task { @MainActor in
                guard let self, self.appState.isRecording else { return }
                self.helperMicKnown = true
                self.helperMicId = deviceId
            }
        }
        captureClient.onFatalFailure = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.appState.isRecording else { return }
                await self.handleXPCCrash()
            }
        }

        do {
            let sentinel = RecordingSentinel(
                startedAt: Date(),
                sessionName: naming.sanitized.isEmpty ? "Recording" : sessionName,
                systemAudioPath: outputDir.appendingPathComponent(naming.baseName + ".wav").path,
                micAudioPath: outputDir.appendingPathComponent(naming.baseName + "_mic.wav").path,
                micDeviceUID: microphoneDeviceId,
                segment: 1,
                chunkIndex: 0
            )
            try RecordingSentinel.write(sentinel, directory: sentinelDirectory)

            try await captureClient.start(
                outputDirectory: outputDir,
                baseName: naming.baseName,
                microphoneDeviceId: microphoneDeviceId,
                systemAudioSource: configManager.config.systemAudioSource
            )
            helperMicKnown = true
            helperMicId = microphoneDeviceId

            try transcriptionRunner.setupChunkedPipeline(
                captureClient: captureClient,
                outputDirectory: outputDir,
                sessionBaseName: naming.chunkBaseName,
                config: config
            )
            transcriptionRunner.startChunkRotation()

            appState.phase = .recording(since: Date())
            xpcRetryCount = 0
            lastCrashAt = nil
            recoveryInFlight = false
            stopRequestedDuringRecovery = false
        } catch {
            RecordingSentinel.delete(directory: sentinelDirectory)
            appState.errorMessage = error.localizedDescription
            notify("Recording Failed", error.localizedDescription)
        }
    }

    public func stopRecording() async {
        // council FV2: if a crash recovery is mid-flight, don't race the helper restart — record
        // the intent and let handleXPCCrash perform the stop once capture is back up.
        if recoveryInFlight {
            Logger.state.info("Stop pressed during crash recovery — deferring to the recovery handler")
            stopRequestedDuringRecovery = true
            appState.phase = .transcribing(progress: "Finishing…")
            return
        }
        Logger.state.info("Recording stopped")
        helperMicKnown = false
        helperMicId = nil
        do {
            let sentinel = RecordingSentinel.read(directory: sentinelDirectory)
            let paths = try await captureClient.stop()
            RecordingSentinel.delete(directory: sentinelDirectory)

            transcriptionRunner.stopChunkRotation()
            appState.phase = .transcribing(progress: "Transcribing…")

            if let rotator = transcriptionRunner.chunkRotator,
               let processor = transcriptionRunner.chunkProcessor {
                // Process the last chunk via the chunked pipeline
                let lastChunk = ChunkRotator.FinalizedChunk(
                    index: rotator.currentChunkInfo.index,
                    systemPath: paths.systemAudio.path,
                    micPath: paths.micAudio.path,
                    startTime: rotator.currentChunkInfo.startTime
                )
                await processor.processLastChunk(lastChunk)

                // Wait for any background chunks still processing
                await processor.awaitAllProcessed()

                // Final merge
                var sessionState = await processor.getSessionState()
                let outputDir = paths.systemAudio.deletingLastPathComponent()
                // Drain capture diagnostics, flush <session>.diag.jsonl only if anomalous, and stamp
                // the always-present provenance into the transcript metadata (#95).
                sessionState.provenance = await captureClient.finalizeSessionDiagnostics(
                    sessionId: sessionState.sessionId,
                    engine: configManager.config.engine.rawValue,
                    recordingDirectory: outputDir
                )
                let result = try await transcriptionRunner.finalize(
                    sessionState: sessionState,
                    outputDirectory: outputDir,
                    config: configManager.config
                )
                await presentCompletedTranscription(result)
            } else {
                // Fallback: no live chunked pipeline in this process (e.g. the app relaunched and
                // re-attached to a still-recording XPC service — Flow A never calls
                // setupChunkedPipeline). A chunked session's session.json is rewritten after every
                // completed chunk, so check for one to rehydrate FIRST — it survives independently
                // of whichever single WAV AudioArchiver has since archived-and-deleted. Only fall
                // back to the legacy stat-based single-file `run()` when there's no chunked session
                // to recover (#135).
                let (sessionOutputDir, sessionId) = Self.fallbackSessionLocation(
                    sentinel: sentinel, stoppedSystemAudioPath: paths.systemAudio.path
                )

                let result: TranscriptionResult?
                if CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: sessionOutputDir, sessionId: sessionId) {
                    let config = configManager.config
                    let (transcriber, diarizer) = try transcriptionRunner.prepareEngine(config: config)
                    // Drain capture diagnostics and stamp the always-present provenance into the
                    // recovered transcript's metadata, same as a clean stop does (#154 finding 1) —
                    // otherwise a recovered session's `sessionState.provenance` stays nil forever.
                    let provenance = await captureClient.finalizeSessionDiagnostics(
                        sessionId: sessionId,
                        engine: config.engine.rawValue,
                        recordingDirectory: sessionOutputDir
                    )
                    result = try await ChunkedSessionRecovery.recover(
                        outputDirectory: sessionOutputDir, sessionId: sessionId, config: config,
                        transcriber: transcriber, diarizer: diarizer, runner: transcriptionRunner,
                        provenance: provenance
                    )
                } else {
                    // Genuine single-file input (non-chunked recording / legacy path).
                    let (systemAudio, micAudio) = Self.legacySingleFileInputs(
                        sentinel: sentinel, stoppedPaths: paths
                    )

                    // #95/council F6: the recovery path also drains diagnostics, flushes the
                    // anomaly-gated <sessionId>.diag.jsonl, and stamps capture_provenance (incl.
                    // recovered=true) — previously only the chunked branch did this.
                    let outputDir = systemAudio.deletingLastPathComponent()
                    let sid = systemAudio.deletingPathExtension().lastPathComponent
                    let provenance = await captureClient.finalizeSessionDiagnostics(
                        sessionId: sid,
                        engine: configManager.config.engine.rawValue,
                        recordingDirectory: outputDir
                    )

                    result = try await transcriptionRunner.run(
                        systemAudio: systemAudio,
                        micAudio: micAudio,
                        outputDirectory: outputDir,
                        config: configManager.config,
                        provenance: provenance
                    )
                }

                if let result {
                    await presentCompletedTranscription(result)
                } else {
                    // Chunked recovery found nothing to salvage (e.g. session.json existed but had
                    // no chunks and no orphan WAVs) — nothing to notify or rename.
                    Logger.state.info("Chunked session recovery found nothing to salvage")
                    appState.phase = .idle
                }
            }

            transcriptionRunner.teardownChunkedPipeline()
        } catch {
            // council FV2 defense-in-depth: stop() can throw (e.g. the helper already cleared
            // isCapturing on a fatal failure that raced this stop). If a live chunked pipeline still
            // holds transcribed chunks, salvage them into a transcript instead of discarding the
            // session with a blind teardown.
            if transcriptionRunner.chunkProcessor != nil, let sentinel = RecordingSentinel.read(directory: sentinelDirectory) {
                await finalizeAbandonedSession(sentinel: sentinel, reingestOrphan: false)
            } else {
                transcriptionRunner.teardownChunkedPipeline()
            }
            RecordingSentinel.delete(directory: sentinelDirectory)
            appState.errorMessage = error.localizedDescription
            notify("Transcription Failed", error.localizedDescription)
            appState.phase = .idle
        }
    }

    // MARK: - Crash recovery

    /// Internal (not private) so the crash-recovery decision paths are reachable from unit tests.
    func handleXPCCrash() async {
        // council FV2: serialize against a user Stop pressed mid-recovery. The defer clears both
        // flags on every exit so a deferred stop never leaks into the next recovery.
        recoveryInFlight = true
        defer { recoveryInFlight = false; stopRequestedDuringRecovery = false }
        // #61: count consecutive failures with time decay, not a cumulative lifetime cap, so a long
        // recording isn't locked out by sporadic, individually-recovered interruptions. A tight
        // crash loop (interruptions within the decay window) still trips the cap.
        let decision = XPCRetryPolicy.register(
            priorCount: xpcRetryCount, lastCrashAt: lastCrashAt, now: Date()
        )
        xpcRetryCount = decision.retryCount
        lastCrashAt = Date()
        captureClient.recordRetry(["attempt": "\(xpcRetryCount)", "giveUp": "\(decision.shouldGiveUp)"])
        Logger.state.warning("XPC interruption during recording — attempt \(self.xpcRetryCount) within the decay window")

        guard let sentinel = RecordingSentinel.read(directory: sentinelDirectory) else {
            Logger.state.error("No sentinel found during crash recovery")
            appState.criticalError = "Recording failed — no recovery data available."
            appState.phase = .idle
            notifyCritical(
                "Recording Failed",
                "Microphone capture crashed. No recovery data found."
            )
            return
        }

        if decision.shouldGiveUp {
            Logger.state.error("All retries exhausted after \(self.xpcRetryCount) interruptions within the decay window")
            // council F3: salvage the live chunked session (re-ingesting the in-progress orphan,
            // since this branch returns before the normal re-ingestion below) so chunks already
            // transcribed aren't discarded with the session.
            await finalizeAbandonedSession(sentinel: sentinel, reingestOrphan: true)
            appState.criticalError = "Recording failed — microphone capture crashed repeatedly. Audio recorded before the failure has been saved."
            appState.phase = .idle
            RecordingSentinel.delete(directory: sentinelDirectory)
            notifyCritical(
                "Recording Failed",
                "Microphone capture crashed after retry. The portion recorded before the failure has been transcribed."
            )
            return
        }

        let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        let baseName: String
        var newSentinel: RecordingSentinel

        // #92: when the chunked pipeline is still live (the common live-crash case), re-ingest the
        // orphaned in-progress chunk and advance the rotator BEFORE restarting capture. Otherwise
        // the orphan's audio is processed by no one and silently dropped from the final transcript.
        if let rotator = transcriptionRunner.chunkRotator,
           let processor = transcriptionRunner.chunkProcessor {
            let orphan = reingestOrphanChunk(rotator: rotator, processor: processor, outputDir: outputDir)
            let plan = rotator.recoverFromCrash()
            let restart = Self.liveRestartPlan(sentinel: sentinel, recoveryPlan: plan, outputDir: outputDir)
            baseName = restart.baseName
            newSentinel = restart.newSentinel
            Logger.state.info("Re-ingested orphan chunk \(orphan.index, privacy: .public) (\(orphan.baseName, privacy: .sensitive)); recovery continues at \(baseName, privacy: .sensitive)")
        } else {
            // No live pipeline (app-relaunch re-attach): there is no rotator to hand us a
            // collision-free index, so derive one directly. #135: name the restart capture in the
            // chunk-index namespace, never the legacy segment counter — the two namespaces can
            // collide. safeRestartChunkIndex owns the collision guard (see CrashRecoveryPlanner).
            let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)
            let idx = CrashRecoveryPlanner.safeRestartChunkIndex(sentinel: sentinel, outputDirectory: outputDir)
            baseName = "\(sessionId)-\(idx)"
            newSentinel = sentinel.incrementedSegment(
                systemAudioPath: outputDir.appendingPathComponent(baseName + ".wav").path,
                micAudioPath: outputDir.appendingPathComponent(baseName + "_mic.wav").path
            )
            // Stamp the freshly computed index directly so the max(nextFreeChunkIndex,
            // chunkIndex+1) floor above stays tight even if a later disk scan fails (#154 finding 6).
            newSentinel.chunkIndex = idx
        }

        do {
            try await captureClient.start(
                outputDirectory: outputDir,
                baseName: baseName,
                microphoneDeviceId: sentinel.micDeviceUID,
                systemAudioSource: configManager.config.systemAudioSource
            )
            try RecordingSentinel.write(newSentinel, directory: sentinelDirectory)
            // council FV2: a Stop pressed while we were restarting now runs cleanly — capture is back
            // up, so a normal stop finalizes the session instead of racing the helper / orphaning it.
            if stopRequestedDuringRecovery {
                stopRequestedDuringRecovery = false
                recoveryInFlight = false
                Logger.state.info("Honoring stop requested during recovery")
                await stopRecording()
                return
            }
            xpcRetryCount = 0
            appState.interruptionWarning = "Recording briefly interrupted. Resuming."
            notify(
                "Recording Resumed",
                "Recording was briefly interrupted and has been restarted."
            )
        } catch {
            Logger.state.error("Restart failed: \(error, privacy: .public)")
            // council F3: the orphan was already re-ingested above, so just finalize what's been
            // processed rather than abandoning the whole session.
            await finalizeAbandonedSession(sentinel: sentinel, reingestOrphan: false)
            appState.criticalError = "Recording failed — could not restart capture: \(error.localizedDescription). Audio recorded before the failure has been saved."
            appState.phase = .idle
            RecordingSentinel.delete(directory: sentinelDirectory)
            notifyCritical(
                "Recording Failed",
                "Microphone capture crashed and could not restart. The portion recorded before the failure has been transcribed."
            )
        }
    }

    /// Best-effort finalize a live chunked session being abandoned after an unrecoverable crash, so
    /// chunks already transcribed to session.json become a real transcript instead of being silently
    /// discarded (council F3). The give-up branch returns before the normal orphan re-ingestion, so
    /// it passes reingestOrphan: true to reclaim the in-progress chunk first.
    private func finalizeAbandonedSession(
        sentinel: RecordingSentinel,
        reingestOrphan: Bool
    ) async {
        guard let processor = transcriptionRunner.chunkProcessor else { return }
        let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        transcriptionRunner.stopChunkRotation()

        if reingestOrphan, let rotator = transcriptionRunner.chunkRotator {
            _ = reingestOrphanChunk(rotator: rotator, processor: processor, outputDir: outputDir)
        }

        await processor.awaitAllProcessed()
        let sessionState = await processor.getSessionState()
        await salvageAbandonedSession(sessionState: sessionState, outputDir: outputDir)
    }

    /// The salvage decision + execution half of `finalizeAbandonedSession`, split out verbatim
    /// behind an internal seam: the `!chunks.isEmpty` guard, provenance stamping, and the
    /// teardown-on-empty path are unit-testable with a crafted `SessionState` — the wrapper above
    /// requires a live `chunkProcessor`, which tests don't have.
    func salvageAbandonedSession(sessionState: SessionState, outputDir: URL) async {
        var sessionState = sessionState
        guard !sessionState.chunks.isEmpty else {
            transcriptionRunner.teardownChunkedPipeline()
            return
        }
        sessionState.provenance = await captureClient.finalizeSessionDiagnostics(
            sessionId: sessionState.sessionId,
            engine: configManager.config.engine.rawValue,
            recordingDirectory: outputDir
        )
        if let result = try? await transcriptionRunner.finalize(
            sessionState: sessionState, outputDirectory: outputDir, config: configManager.config
        ) {
            appState.lastJsonPath = result.jsonPath.path
            appState.lastTranscriptPath = result.jsonPath.path
            Logger.state.info("Salvaged abandoned chunked session → \(result.jsonPath.lastPathComponent, privacy: .sensitive)")
        }
        transcriptionRunner.teardownChunkedPipeline()
    }

    // MARK: - Shared steps (deduplicated from MenuView)

    /// The post-transcription success sequence, previously duplicated verbatim in both the chunked
    /// and fallback branches of `stopRecording`: publish the transcript paths, return to idle,
    /// notify, then hand off to the rename dialog + auto-summary.
    private func presentCompletedTranscription(_ result: TranscriptionResult) async {
        appState.lastJsonPath = result.jsonPath.path
        appState.lastTranscriptPath = result.jsonPath.path
        appState.phase = .idle
        // Say so when the capture layer flagged something. This used to be an unconditional
        // "Transcription Complete" while `capture_provenance` sat right here recording that the
        // recording was compromised — the app knew and the user did not (#58).
        // Off the main actor: this is a synchronous file read of a transcript that can reach several
        // hundred KB for a long meeting, on a path that has just finished writing it. `RecordingCoordinator`
        // is @MainActor, so doing it inline would block the UI at exactly the wrong moment.
        let jsonPath = result.jsonPath
        let anomalies = await Task.detached(priority: .utility) {
            CaptureQualityNotice.anomalyCount(inTranscriptAt: jsonPath)
        }.value
        if anomalies > 0 {
            Logger.state.error(
                "Completed transcript carries \(anomalies, privacy: .public) capture anomalies — surfacing to the user"
            )
        }
        notify(
            CaptureQualityNotice.completionTitle(anomalyCount: anomalies),
            CaptureQualityNotice.completionBody(
                fileName: result.jsonPath.lastPathComponent, anomalyCount: anomalies)
        )
        presentTranscript(result.jsonPath, configManager.config)
    }

    /// Re-ingest the orphaned in-progress chunk into the processor, previously duplicated verbatim
    /// in `handleXPCCrash` and `finalizeAbandonedSession`. Uses the rotator's live-index base name,
    /// NOT the stale sentinel path. Returns the orphan's (index, baseName) for logging.
    private func reingestOrphanChunk(
        rotator: ChunkRotator, processor: ChunkProcessor, outputDir: URL
    ) -> (index: Int, baseName: String) {
        let orphan = rotator.currentChunkInfo
        let orphanBase = rotator.currentBaseName  // live-index base, NOT the stale sentinel path
        processor.processChunk(Self.orphanChunk(
            index: orphan.index, startTime: orphan.startTime,
            liveBaseName: orphanBase, outputDir: outputDir
        ))
        return (orphan.index, orphanBase)
    }
}
