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
    /// The helper found the tap running without its System Audio Recording permission (#220): the
    /// app opens its repair window. Injected because Core can't present AppKit windows.
    private let onSystemAudioPermissionDenied: @MainActor () -> Void
    /// Present the alarm UI (floating window + notification): (the DUE alarms — the ones the per-kind
    /// notify floor lets present now, oldest first; the kinds that are new since the last presentation).
    /// Called only when something is due.
    private let presentAlarmsUI: @MainActor ([ActiveAlarm], [AlarmKind]) -> Void

    // MARK: - Alarm state (§6)

    /// How often the helper's alarm state is pulled while recording (§6.2). Tests shorten it.
    var statusPollInterval: Duration = .seconds(5)
    private var statusPoll: Task<Void, Never>?
    /// Consecutive `captureStatus` polls that got no answer; 3 raise `helperUnresponsive` (§8.13).
    private var missedPolls = 0
    /// Consecutive polls answering `isCapturing == false`; 2 take the crash-recovery path.
    private var notCapturingPolls = 0
    /// The kinds the last `presentAlarms` saw, so a kind is "new" only once per appearance.
    private var presentedKinds: Set<AlarmKind> = []
    /// The presenter's cadence while NOT recording (§6.3 "every 2 min while any alarm is active"): only
    /// while an alarm is active (one that outlives a recording) — no timer at all otherwise, so an idle
    /// app with nothing to say has zero wakeups. Tests shorten it.
    var idleRealarmInterval: Duration = .seconds(AlarmRealarmPolicy.notifyInterval)
    private var idleRealarm: Task<Void, Never>?
    /// Internal for tests.
    var idleRealarmActive: Bool { idleRealarm != nil }

    // MARK: - Restart confirmation (§8.4, §8.5)

    /// How long the restarted capture must deliver frames — with no newer crash and no mic
    /// NotDelivering alarm — before the retry streak resets (L9). Tests set it.
    public var recoveryConfirmationSeconds: TimeInterval = 60
    /// A restart is waiting for the new helper's first mic frames before it says "Resumed".
    private var awaitingRecoveryFrames = false
    /// When the restarted capture delivered its first mic frames: the confirmation window's start.
    private var recoveryFramesAt: Date?
    /// The last time a snapshot carried `micNotDelivering`: inside the window it voids the confirmation.
    private var lastMicAlarmAt: Date?
    /// The awaited restart is a relaunch (Flow B): audio between the crash and the relaunch was lost,
    /// and "Resumed" says so — until L7's `recordingResumedWithGap` states the gap exactly.
    private var restartLostAudio = false
    /// Builds the engines launch recovery transcribes with; nil = `transcriptionRunner.prepareEngine`.
    /// Injected so tests never construct a real engine.
    private let engineFactory: (@MainActor (Config) throws -> (any TranscriptionEngine, (any DiarizationProvider)?))?

    // MARK: - Lifecycle state (previously `@State` in MenuView)

    /// Consecutive XPC-crash count within the decay window (#61). Internal for test seeding.
    var xpcRetryCount = 0
    var lastCrashAt: Date?
    /// True while handleXPCCrash is mid-recovery (across its `await start()`). A user Stop in that
    /// window must not race the helper restart (council FV2) — it sets stopRequestedDuringRecovery
    /// and the recovery handler honors it once capture is back up.
    var recoveryInFlight = false
    var stopRequestedDuringRecovery = false
    /// True while stopRecording() is running (it suspends on the helper's stop). A second Stop in that
    /// window — a double-tap, or a future programmatic caller — is ignored rather than reaching the
    /// helper and the transcription pipeline twice. Internal for tests.
    var stopInFlight = false
    /// True once the helper has reported which device it is actually capturing on (post auto-switch).
    /// When false, `helperMicId` is meaningless and the UI falls back to the user's selection.
    public private(set) var helperMicKnown: Bool = false
    /// The mic device the helper is ACTUALLY capturing on, reported via the reverse channel after an
    /// auto-switch. Valid only when `helperMicKnown` is true. `nil` = helper on system default;
    /// non-nil = helper on this specific device. Both cleared when recording stops.
    public private(set) var helperMicId: String? = nil
    /// The mic being recorded, process-wide, so no level meter opens it while the helper holds it
    /// (#192). The single source of truth: `helperMicKnown`/`helperMicId` mirror it (see
    /// `recordingMicrophoneChanged`), so any writer — including one outside the coordinator — keeps
    /// the menu's mic label right too.
    private let recordingMicrophone: RecordingMicrophone

    private func setHelperMic(_ deviceId: String?) {
        recordingMicrophone.set(deviceId)
    }

    private func clearHelperMic() {
        recordingMicrophone.clear()
    }

    public init(
        appState: AppState,
        captureClient: any RecordingCaptureClient,
        transcriptionRunner: TranscriptionRunner,
        configManager: ConfigManager,
        sentinelDirectory: URL? = nil,
        notify: @escaping @MainActor (String, String) -> Void,
        notifyCritical: @escaping @MainActor (String, String) -> Void,
        presentTranscript: @escaping @MainActor (URL, Config) -> Void,
        onSystemAudioPermissionDenied: @escaping @MainActor () -> Void = {},
        presentAlarmsUI: @escaping @MainActor ([ActiveAlarm], [AlarmKind]) -> Void = { _, _ in },
        engineFactory: (@MainActor (Config) throws -> (any TranscriptionEngine, (any DiarizationProvider)?))? = nil,
        recordingMicrophone: RecordingMicrophone = .shared
    ) {
        self.onSystemAudioPermissionDenied = onSystemAudioPermissionDenied
        self.presentAlarmsUI = presentAlarmsUI
        self.engineFactory = engineFactory
        self.recordingMicrophone = recordingMicrophone
        self.appState = appState
        self.captureClient = captureClient
        self.transcriptionRunner = transcriptionRunner
        self.configManager = configManager
        self.sentinelDirectory = sentinelDirectory
        self.notify = notify
        self.notifyCritical = notifyCritical
        self.presentTranscript = presentTranscript
        recordingMicrophone.addObserver(self)
        recordingMicrophoneChanged(to: recordingMicrophone.current)   // a re-attach may have marked it already
        updateIdleRealarm()
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

        // Pre-flight (#193): the built-in mic stays the default input device — and keeps delivering
        // full-rate buffers of exact digital zero — while the lid is closed. Warn BEFORE capture
        // starts, not only via the live exact-zero detector once the meeting is already underway.
        // Non-blocking: recording proceeds either way, exactly like every other interruption banner.
        // `isLidClosed()`/`isBuiltInMicSelected(deviceId:)` are synchronous IOKit/
        // CoreAudio HAL lookups. Normally sub-millisecond, but a HAL daemon restart or sleep/wake
        // transition can occasionally stall them — hop to a detached task so a rare stall never
        // blocks the main actor. Both are pure/static with no actor isolation, so this is a pure
        // scheduling change; nothing before this point in `startRecording` depends on ordering.
        let (lidClosed, isBuiltInMic) = await Task.detached {
            (ClamshellMicGuard.isLidClosed(), ClamshellMicGuard.isBuiltInMicSelected(deviceId: microphoneDeviceId))
        }.value
        // Re-entrancy guard: the await above is a genuine suspension point (unlike the two
        // synchronous IOKit/CoreAudio calls it replaced), so a second startRecording call fired
        // during it — e.g. a double-tap of the record control before the UI disables it — must not
        // race this one into writing a second sentinel / starting a second capture. Same
        // "bail if the state moved" pattern already used by the callback guards below. Checked
        // BEFORE the warning is set, so a call that loses the race never shows a banner for a
        // recording it isn't the one driving.
        guard appState.isIdle else { return }
        if ClamshellMicGuard.shouldWarn(lidClosed: lidClosed, isBuiltInMic: isBuiltInMic) {
            appState.interruptionWarning = ClamshellMicGuard.warningMessage
        }

        let config = configManager.config
        let naming = Self.startNaming(sessionName: sessionName, now: Date())

        let outputDir = URL(fileURLWithPath: config.recordingDirectory)
            .appendingPathComponent(naming.dayDir)

        // Wired before the helper starts, so nothing it reports in its first seconds is lost.
        wireCaptureCallbacks()

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

            // Before the helper opens the mic, so no meter opens it meanwhile (#192).
            setHelperMic(microphoneDeviceId)
            try await captureClient.start(
                outputDirectory: outputDir,
                baseName: naming.baseName,
                microphoneDeviceId: microphoneDeviceId,
                systemAudioSource: configManager.config.systemAudioSource,
                options: CaptureOptions(config: config),
                sessionId: naming.chunkBaseName
            )

            try transcriptionRunner.setupChunkedPipeline(
                captureClient: captureClient,
                outputDirectory: outputDir,
                sessionBaseName: naming.chunkBaseName,
                config: config
            )
            transcriptionRunner.startChunkRotation()

            appState.phase = .recording(since: Date())
            startStatusPoll()
            xpcRetryCount = 0
            lastCrashAt = nil
            recoveryInFlight = false
            stopRequestedDuringRecovery = false
            // A restart from an earlier recording that never saw frames must not say "Resumed" here.
            awaitingRecoveryFrames = false
            recoveryFramesAt = nil
            lastMicAlarmAt = nil
            restartLostAudio = false
        } catch {
            clearHelperMic()
            captureClient.captureEnded()   // the recording never began: disarm crash detection (C1)
            RecordingSentinel.delete(directory: sentinelDirectory)
            appState.errorMessage = error.localizedDescription
            notify("Recording Failed", error.localizedDescription)
        }
    }

    /// The mid-recording Change Microphone switch. Marks the new mic as the recording's BEFORE the
    /// helper opens it, so no level meter opens it meanwhile (#192); on failure the previous mic stays
    /// marked. Also records it in the sentinel, so a crash restart resumes on the mic the user switched
    /// TO — not the one the recording began on, which may be the very mic they left (a lid-closed
    /// built-in delivering zeros, #193).
    ///
    /// Not recording (it ended while the dialog was open): nothing to switch live. Mid crash recovery:
    /// refused, because the restart is about to rewrite the sentinel from its own copy.
    public func switchMicrophone(to deviceId: String?) async throws {
        guard appState.isRecording else { return }
        guard !recoveryInFlight else { throw MicSwitchError.recoveryInProgress }
        // Stop is already running (the phase flips only once the helper's stop returns): the recording
        // is ending, so there is nothing to switch — and the helper must not get a switch mid-stop.
        // Returns rather than throws, unlike mid-recovery: the caller then saves the pick as the
        // preference for the next recording, which is what the user asked for. Intentional.
        guard !stopInFlight else {
            Logger.state.info("Mic switch requested while Stop is in flight — not switching; the pick is kept as the next-recording preference")
            return
        }
        // Three states: `.none` = nothing marked (not expected mid-recording — see the restore below),
        // `.some(nil)` = recording on the system default, `.some(id)` = recording on that device.
        let before = recordingMicrophone.current
        setHelperMic(deviceId)
        do {
            try await captureClient.updateMicrophone(deviceId: deviceId)
        } catch {
            // Put back exactly what was there — unless, during the await, the recording ended (stop
            // already released the mic) or the helper reported a different mic of its own.
            // Every path into a live recording (start, crash restart, Flow A/B re-attach) marks its mic
            // first, so `before` is always set here. Should a future path forget, keep the target marked
            // rather than clear: "nothing is recording" mid-recording would let meters open its mic.
            // Equality on the whole String?? — the marker must still hold exactly the mic we wrote
            // (`.some(nil)` = system default counts; a different mic reported by the helper does not).
            if appState.isRecording, recordingMicrophone.current == .some(deviceId),
               case .some(let marked) = before {
                recordingMicrophone.set(marked)
            }
            throw error
        }
        // The recording ended normally while the helper was switching (Stop during the switch): there
        // is no recovery file to update any more, and nothing to warn about. Stop deletes the sentinel
        // and leaves the recording phase in one synchronous step, so this check can't fall between.
        guard appState.isRecording else { return }
        // The switch itself worked. If the recovery file can't record it — unwritable, or missing
        // (deleted mid-recording) — a crash restart would resume on the mic the user left, possibly the
        // dead one they switched away from. Say so rather than stay silent.
        guard var sentinel = RecordingSentinel.read(directory: sentinelDirectory) else {
            Logger.state.error("Could not record the switched mic: the recovery file is missing during a live recording")
            warnRecoveryNotUpdated()
            return
        }
        sentinel.micDeviceUID = deviceId
        do {
            try RecordingSentinel.write(sentinel, directory: sentinelDirectory)
        } catch {
            Logger.state.error("Could not record the switched mic in the sentinel: \(error, privacy: .public)")
            warnRecoveryNotUpdated()
        }
    }

    private func warnRecoveryNotUpdated() {
        notify(
            "Recovery File Not Updated",
            "The microphone switch worked, but if the recording is interrupted it may resume on the previous microphone."
        )
    }

    public enum MicSwitchError: Error, LocalizedError {
        case recoveryInProgress
        public var errorDescription: String? {
            "The recording is recovering from an interruption. Try again in a moment."
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
        guard !stopInFlight else {
            Logger.state.info("Stop already in progress — ignoring a second request")
            return
        }
        stopInFlight = true
        defer { stopInFlight = false }
        stopStatusPoll()
        Logger.state.info("Recording stopped")
        do {
            let sentinel = RecordingSentinel.read(directory: sentinelDirectory)
            let paths = try await captureClient.stop()
            clearHelperMic()   // only now has the helper let go of the mic (#192)
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
            // stop() failed, so unlike the success path there is no "helper has let go" moment to wait
            // for: release the marker best-effort. The realistic causes (XPC crash, fatal failure) mean
            // the helper is already gone and holds no mic.
            clearHelperMic()
            // council FV2 defense-in-depth: stop() can throw (e.g. the helper already cleared
            // isCapturing on a fatal failure that raced this stop). If a live chunked pipeline still
            // holds transcribed chunks, salvage them into a transcript instead of discarding the
            // session with a blind teardown.
            let sentinel = RecordingSentinel.read(directory: sentinelDirectory)
            let outcome: SalvageOutcome
            if transcriptionRunner.chunkProcessor != nil, let sentinel {
                outcome = await finalizeAbandonedSession(sentinel: sentinel, reingestOrphan: false)
            } else {
                transcriptionRunner.teardownChunkedPipeline()
                outcome = unsalvagedOutcome(sentinel: sentinel, why: error.localizedDescription)
            }
            RecordingSentinel.delete(directory: sentinelDirectory)
            appState.errorMessage = error.localizedDescription
            // #155: this catch is the Flow-A re-attach stop path's only signal to the user — the
            // sentinel above is deleted unconditionally, so relaunching will not retry. It says what
            // is on disk (§7.4 P6): a user who sees only "Transcription Failed" has no way to know
            // their raw .wav/.m4a files are still safely there.
            notifyCritical(
                "Transcription Failed",
                RecoveryMessages.stopFailed(after: outcome, error: error.localizedDescription)
            )
            appState.phase = .idle
        }
    }

    // MARK: - Capture callbacks + alarms (§6)

    /// Every `captureClient` closure, in one place: set by `startRecording` before the helper starts
    /// and again by `handleXPCCrash` before the restart, so a restarted helper reports into the same
    /// closures. `[weak self]`: the coordinator retains the capture client, so a strong capture would
    /// cycle coordinator → captureClient → closure → coordinator.
    private func wireCaptureCallbacks() {
        captureClient.onServiceCrash = { [weak self] in
            Task { @MainActor in
                guard let self, self.appState.isRecording else { return }
                await self.handleXPCCrash()
            }
        }
        // #86: a benign route change no longer reads as a crash. The helper restarts the stream in
        // place (onRestartInPlace) or the connection blips without a crash report (onBriefInterruption)
        // — both keep recording silently. Only a fatal give-up escalates.
        // Routine mic switches are handled by onMicDeviceChanged (label refresh only, no banner) —
        // for recordings this coordinator started and the ones it re-attached at launch alike.
        captureClient.onMicDeviceChanged = { [weak self] deviceId in
            Task { @MainActor in
                guard let self, self.appState.isRecording else { return }
                self.setHelperMic(deviceId)
            }
        }
        captureClient.onFatalFailure = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.appState.isRecording else { return }
                await self.handleXPCCrash()
            }
        }
        // A transient notice only: the sticky state is the helper's `remoteRecoveryFailed` alarm.
        captureClient.onSystemAudioUnrecoverable = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.appState.isRecording else { return }
                self.appState.interruptionWarning = "Remote audio couldn’t be recovered — only your microphone is recording."
            }
        }
        // #193/#196: a live capture-quality anomaly, surfaced while there is still time to react. A
        // transient notice: the repair window opens from `presentAlarms`, on the helper's alarm.
        captureClient.onQualityAnomaly = { [weak self] kind, message in
            Task { @MainActor in
                guard let self, self.appState.isRecording else { return }
                self.appState.noteQualityAnomaly(kind: kind, message: message)
            }
        }
        captureClient.onAlarmsChanged = { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.appState.isRecording else { return }
                self.applySnapshot(snapshot)
                self.presentAlarms()
            }
        }
        captureClient.onFirstFrames = { [weak self] track, helperSessionId in
            Task { @MainActor in self?.noteFirstFrames(track: track, helperSessionId: helperSessionId) }
        }
        captureClient.onRealAudio = { [weak self] track, helperSessionId in
            Task { @MainActor in
                guard let self, self.appState.isRecording else { return }
                self.appState.noteRealAudio(track: track, helperSessionId: helperSessionId)
                self.presentAlarms()
            }
        }
        captureClient.onWriteSucceeded = { [weak self] helperSessionId in
            Task { @MainActor in
                guard let self, self.appState.isRecording else { return }
                self.appState.noteWriteSucceeded(helperSessionId: helperSessionId)
                self.presentAlarms()
            }
        }
    }

    /// Pull the helper's alarm state every `statusPollInterval` while recording (§6.2). Holds the
    /// coordinator only while polling, never across the sleep.
    private func startStatusPoll() {
        statusPoll?.cancel()
        missedPolls = 0
        notCapturingPolls = 0
        // The previous recording's alarms went with it, unpresented: the same kind in this one is new.
        presentedKinds.formIntersection(appState.activeAlarms.keys)
        statusPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.statusPollInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.appState.isRecording else { return }
                await self.pollHelperStatus()
            }
        }
    }

    private func stopStatusPoll() {
        statusPoll?.cancel()
        statusPoll = nil
        missedPolls = 0
        notCapturingPolls = 0
    }

    /// Push (`onAlarmsChanged`) and pull (`pollHelperStatus`) land here: ONE path, so every mic
    /// NotDelivering alarm — whichever channel carried it — voids a pending restart confirmation (§8.5;
    /// the pull is the source of truth, §6.2). Returns whether the registry adopted the snapshot.
    @discardableResult
    private func applySnapshot(_ snapshot: CaptureStatusSnapshot) -> Bool {
        guard appState.applyHelperSnapshot(snapshot) else { return false }
        if snapshot.alarms.contains(where: { $0.kind == .micNotDelivering }) { lastMicAlarmAt = Date() }
        return true
    }

    /// One pull. Three unanswered in a row raise `helperUnresponsive`; any answer clears it (§8.13).
    /// Two in a row answering "not capturing" mean the recording died without an XPC event: the same
    /// crash-recovery path as a crash (restart under the retry cap) — never a silent dead recording.
    func pollHelperStatus() async {
        let snapshot = await captureClient.captureStatus()
        // The recording may have ended during the (up to 3 s) wait: its alarms went with it.
        guard appState.isRecording else { return }
        if let snapshot {
            missedPolls = 0
            appState.clearAppAlarm(.helperUnresponsive)
            if applySnapshot(snapshot) {
                // A restart or a stop legitimately passes through "not capturing": never counted then.
                notCapturingPolls = snapshot.isCapturing || recoveryInFlight || stopInFlight ? 0 : notCapturingPolls + 1
            }
            if notCapturingPolls >= 2 {
                notCapturingPolls = 0
                Logger.state.error("The helper answers but is not capturing (2 polls) — crash recovery")
                captureClient.record(.xpcInterruption, .anomaly, ["classification": "not capturing", "detectedBy": "status poll"])
                presentAlarms()
                await handleXPCCrash()
                return
            }
        } else {
            missedPolls += 1
            if missedPolls >= 3 {
                appState.raiseAppAlarm(.helperUnresponsive, message: "The capture helper stopped answering. The recording may have stopped — check the audio files after you stop.")
            }
        }
        presentAlarms()
    }

    /// Rows are immediate; the UI (window + notification) follows the per-kind notify floor (F2):
    /// a kind is presented only when `AlarmRealarmPolicy.shouldRenotify` says so — at once if it has
    /// not notified within 2 min, otherwise at the next 2-minute mark. Acknowledgeable kinds are
    /// raised with no floor and present at once. The permission kinds open the repair window when
    /// they are new (it has its own snooze).
    func presentAlarms(now: Date = Date()) {
        let active = appState.alarms.sorted
        let newKinds = active.map(\.kind).filter { !presentedKinds.contains($0) }
        presentedKinds = Set(active.map(\.kind))
        if newKinds.contains(.remotePermissionDenied) || newKinds.contains(.remoteCantConfirm) { onSystemAudioPermissionDenied() }
        let due = active.filter { AlarmRealarmPolicy.shouldRenotify($0, now: now) }
        guard !due.isEmpty else { return }
        for alarm in due { appState.markNotified(alarm.kind, now: now) }
        let dueKinds = Set(due.map(\.kind))
        presentAlarmsUI(due, newKinds.filter { dueKinds.contains($0) })
    }

    /// Starts or stops the idle presenter from the alarms and the phase, then re-evaluates on their next
    /// change (Observation: one outstanding registration, re-armed here only). While recording, the
    /// status poll presents instead.
    private func updateIdleRealarm() {
        let needed = !appState.isRecording && !appState.alarms.isEmpty
        if needed, idleRealarm == nil {
            idleRealarm = Task { [weak self] in
                while !Task.isCancelled {
                    guard let interval = self?.idleRealarmInterval else { return }
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    self.presentAlarms()
                }
            }
        } else if !needed, let timer = idleRealarm {
            timer.cancel()
            idleRealarm = nil
        }
        withObservationTracking {
            _ = appState.alarms
            _ = appState.phase
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIdleRealarm() }
        }
    }

    /// The new helper's frames clear the previous helper's DELIVERY alarms on that track (L2). After a
    /// restart, the first MIC frames are what "Recording Resumed" waits for (§8.4) — never `start()`
    /// returning — and they open the confirmation window that may reset the retry streak (L9).
    func noteFirstFrames(track: CaptureTrack, helperSessionId: String, now: Date = Date()) {
        // A relaunch's restart (Flow B) awaits frames before the phase is `.recording`: they count too.
        guard appState.isRecording || awaitingRecoveryFrames else { return }
        appState.noteFirstFrames(track: track, helperSessionId: helperSessionId)
        presentAlarms(now: now)
        guard track == .mic, awaitingRecoveryFrames else { return }
        awaitingRecoveryFrames = false
        recoveryFramesAt = now
        lastMicAlarmAt = nil
        if restartLostAudio {
            appState.interruptionWarning = "Recording was briefly interrupted. Some audio may have been lost."
            notify("Recording Resumed", "Recording was briefly interrupted. Some audio may have been lost.")
        } else {
            appState.interruptionWarning = "Recording briefly interrupted. Resumed."
            notify("Recording Resumed", "Recording was briefly interrupted and has been restarted.")
        }
        let window = recoveryConfirmationSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            self?.confirmRecoveryHealthy()
        }
    }

    /// L9 / §8.5: the streak resets only after `recoveryConfirmationSeconds` of frames since the
    /// restart's first frame, with no newer crash and no mic NotDelivering alarm in that window.
    func confirmRecoveryHealthy(now: Date = Date()) {
        guard appState.isRecording, let since = recoveryFramesAt,
              now.timeIntervalSince(since) >= recoveryConfirmationSeconds,
              lastCrashAt.map({ $0 <= since }) ?? true,
              lastMicAlarmAt.map({ $0 <= since }) ?? true,
              appState.activeAlarms[.micNotDelivering] == nil else { return }
        xpcRetryCount = 0
        recoveryFramesAt = nil
    }

    // MARK: - Crash recovery

    /// Internal (not private) so the crash-recovery decision paths are reachable from unit tests.
    func handleXPCCrash() async {
        // council FV2: serialize against a user Stop pressed mid-recovery. The defer clears both
        // flags on every exit so a deferred stop never leaks into the next recovery.
        recoveryInFlight = true
        defer {
            recoveryInFlight = false
            stopRequestedDuringRecovery = false
            // Every give-up path ends the recording without stopRecording(); release the mic record.
            if appState.isIdle { clearHelperMic() }
        }
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
            stopStatusPoll()
            captureClient.captureEnded()
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
            let outcome = await finalizeAbandonedSession(sentinel: sentinel, reingestOrphan: true)
            appState.criticalError = "Recording failed — microphone capture crashed repeatedly. Audio recorded before the failure has been saved."
            appState.phase = .idle
            stopStatusPoll()
            captureClient.captureEnded()
            RecordingSentinel.delete(directory: sentinelDirectory)
            // §7.4 P6: says what the salvage actually wrote — never "has been transcribed" when nothing was.
            notifyCritical("Recording Failed", RecoveryMessages.recordingFailed(after: outcome))
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
            // collide. CrashRecoveryPlanner.planRestart owns the collision guard + naming
            // sequence, shared by every no-live-pipeline restart site (#170).
            let restart = CrashRecoveryPlanner.planRestart(sentinel: sentinel, outputDirectory: outputDir)
            baseName = restart.baseName
            newSentinel = restart.newSentinel
        }

        do {
            // The restart resumes on this mic: mark it before the helper opens it (#192). If the restart
            // fails, the defer above releases it once the phase has gone idle.
            setHelperMic(sentinel.micDeviceUID)
            // The restarted helper must report into the same closures (scan B P0.4(5)).
            wireCaptureCallbacks()
            // L9: `start()` returning proves nothing — the helper replies before its first frame, and
            // a first-sample crash comes back as another interruption. The streak resets only after
            // confirmed frames (`confirmRecoveryHealthy`), and "Resumed" waits for them (§8.4). Armed
            // BEFORE the start: its first frames may land while `start()` is still being awaited.
            awaitingRecoveryFrames = true
            recoveryFramesAt = nil
            restartLostAudio = false
            try await captureClient.start(
                outputDirectory: outputDir,
                baseName: baseName,
                microphoneDeviceId: sentinel.micDeviceUID,
                systemAudioSource: configManager.config.systemAudioSource,
                options: CaptureOptions(config: configManager.config),
                sessionId: stripSegmentSuffix(sentinel.systemAudioPath)
            )
            try RecordingSentinel.write(newSentinel, directory: sentinelDirectory)
            // council FV2: a Stop pressed while we were restarting now runs cleanly — capture is back
            // up, so a normal stop finalizes the session instead of racing the helper / orphaning it.
            if stopRequestedDuringRecovery {
                stopRequestedDuringRecovery = false
                recoveryInFlight = false
                awaitingRecoveryFrames = false
                Logger.state.info("Honoring stop requested during recovery")
                await stopRecording()
                return
            }
            // The old helper's alarms stay: the new helper's snapshot turns them stale, and only its
            // evidence on that track clears each one (§6.2).
            if awaitingRecoveryFrames { appState.interruptionWarning = "Recording restarted — waiting for audio…" }
        } catch {
            Logger.state.error("Restart failed: \(error, privacy: .public)")
            awaitingRecoveryFrames = false
            // council F3: the orphan was already re-ingested above, so just finalize what's been
            // processed rather than abandoning the whole session.
            let outcome = await finalizeAbandonedSession(sentinel: sentinel, reingestOrphan: false)
            appState.criticalError = "Recording failed — could not restart capture: \(error.localizedDescription). Audio recorded before the failure has been saved."
            appState.phase = .idle
            stopStatusPoll()
            captureClient.captureEnded()
            RecordingSentinel.delete(directory: sentinelDirectory)
            notifyCritical("Recording Failed", RecoveryMessages.recordingFailed(after: outcome))
        }
    }

    // MARK: - Launch recovery (§8.3)

    /// A recording was running when the app last quit or crashed (the sentinel survived): re-attach to
    /// a helper that is still capturing (Flow A), rehydrate a chunked session (Flow B, chunked), or
    /// restart capture on partial legacy audio (Flow B). Formerly `TranscriberApp.recoverIfNeeded`;
    /// moved here so every crash path is owned — and testable — in one place (§8.3, §8.5).
    public func recoverAtLaunch() async {
        guard let sentinel = RecordingSentinel.read(directory: sentinelDirectory) else { return }

        Logger.state.info("Sentinel found — checking recovery (session: \(sentinel.sessionName, privacy: .sensitive), segment: \(sentinel.segment))")

        // Check if sentinel is stale (from before last boot)
        let bootTime = ProcessInfo.processInfo.systemUptime
        let bootDate = Date().addingTimeInterval(-bootTime)
        if sentinel.startedAt < bootDate {
            Logger.state.info("Stale sentinel from before last boot — cleaning up")
            RecordingSentinel.delete(directory: sentinelDirectory)
            captureClient.captureEnded()
            return
        }

        // Flow A: Is XPC service still alive and capturing?
        if await captureClient.isCapturing() {
            Logger.state.info("XPC service alive — re-attaching (Flow A)")
            appState.phase = .recording(since: sentinel.startedAt)
            setHelperMic(sentinel.micDeviceUID)   // keep level meters off it (#192)
            captureClient.recordLaunchRecovery(["flow": "A", "reattach": "true"])
            captureClient.captureReattached()   // no start() in this process: arm crash detection (C1)
            wireCaptureCallbacks()
            startStatusPoll()
            // Restore the helper's alarm state now: the pull on connect ran before anything listened.
            Task { await pollHelperStatus() }
            return
        }

        // Flow B: XPC is dead. A chunked session's session.json is rewritten after every
        // completed chunk, so it survives independently of whichever single WAV
        // AudioArchiver has since deleted — check for a recoverable chunked session FIRST,
        // before the stat-based single-file check below (which stats a WAV that a chunked
        // recording archives-and-deletes at the first rotation, so it would always read 0
        // bytes and wrongly conclude "no usable audio files") (#135).
        let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)
        if CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: outputDir, sessionId: sessionId) {
            Logger.state.info("Recoverable chunked session found — rehydrating (Flow B, chunked)")
            await salvageAtLaunch(sentinel: sentinel, outputDir: outputDir)
            return
        }

        // Flow B (legacy, non-chunked/single-file): check for partial audio files
        let sysSize = (try? FileManager.default.attributesOfItem(
            atPath: sentinel.systemAudioPath
        )[.size] as? Int) ?? 0

        guard sysSize > 44 else {
            Logger.state.info("No usable audio files — cleaning up sentinel")
            RecordingSentinel.delete(directory: sentinelDirectory)
            captureClient.captureEnded()
            return
        }

        Logger.state.info("Partial audio found (\(sysSize) bytes) — restarting recording (Flow B)")
        let seg = sentinel.segment + 1
        // #135: name the restart capture in the chunk-index namespace, never the legacy segment
        // counter — the two namespaces can collide. CrashRecoveryPlanner.planRestart owns the
        // collision guard + naming sequence, shared by every no-live-pipeline restart site (#170).
        let restart = CrashRecoveryPlanner.planRestart(sentinel: sentinel, outputDirectory: outputDir)
        // Wired and armed BEFORE the start, as the other start sites do: a helper reporting (first
        // frames included) while `start()` is awaited must find someone listening. Honest "Resumed"
        // (§8.4): announced by `noteFirstFrames` once the new helper delivers.
        wireCaptureCallbacks()
        awaitingRecoveryFrames = true
        recoveryFramesAt = nil
        restartLostAudio = true
        do {
            try await captureClient.start(
                outputDirectory: outputDir,
                baseName: restart.baseName,
                microphoneDeviceId: sentinel.micDeviceUID,
                systemAudioSource: configManager.config.systemAudioSource,
                options: CaptureOptions(config: configManager.config),
                sessionId: stripSegmentSuffix(sentinel.systemAudioPath)
            )
            try RecordingSentinel.write(restart.newSentinel, directory: sentinelDirectory)
            appState.phase = .recording(since: sentinel.startedAt)
            setHelperMic(sentinel.micDeviceUID)   // keep level meters off it (#192)
            captureClient.recordLaunchRecovery(["flow": "B", "segment": "\(seg)"])
            startStatusPoll()
            if awaitingRecoveryFrames { appState.interruptionWarning = "Recording restarted — waiting for audio…" }
        } catch {
            Logger.state.error("Flow B recovery failed: \(error, privacy: .public)")
            awaitingRecoveryFrames = false
            appState.criticalError = "Recording failed — could not restart after crash recovery."
            RecordingSentinel.delete(directory: sentinelDirectory)
            captureClient.captureEnded()
            notifyCritical(
                "Recording Failed",
                "Crash recovery attempted but could not restart recording."
            )
        }
    }

    /// A crashed recording that is not resumed: transcribe what reached disk, present it like a normal
    /// stop (completion notice + rename), and say loudly — critical notice + sticky `recordingStopped`
    /// alarm — that the recording STOPPED and what was written (§7.4 P6). L7 calls this from its
    /// relaunch decision.
    func salvageAtLaunch(sentinel: RecordingSentinel, outputDir: URL) async {
        let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)
        let chunkCount = chunksOnDisk(outputDir: outputDir, sessionId: sessionId)
        appState.phase = .transcribing(progress: "Recovering…")
        let outcome: SalvageOutcome
        var recovered: TranscriptionResult?
        do {
            let config = configManager.config
            let (transcriber, diarizer) = try prepareEngines(config: config)
            // Drain capture diagnostics and stamp the always-present provenance into the
            // recovered transcript's metadata, same as a clean stop does (#154 finding 1) —
            // otherwise a recovered session's `sessionState.provenance` stays nil forever.
            let provenance = await captureClient.finalizeSessionDiagnostics(
                sessionId: sessionId,
                engine: config.engine.rawValue,
                recordingDirectory: outputDir
            )
            if let result = try await ChunkedSessionRecovery.recover(
                outputDirectory: outputDir, sessionId: sessionId, config: config,
                transcriber: transcriber, diarizer: diarizer, runner: transcriptionRunner,
                provenance: provenance
            ) {
                Logger.state.info("Recovered chunked session → \(result.jsonPath.lastPathComponent, privacy: .sensitive)")
                recovered = result
                outcome = SalvageOutcome(kind: .transcriptWritten(result.jsonPath), chunkCount: chunkCount)
            } else {
                Logger.state.info("Chunked session had nothing to recover")
                outcome = SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0)
            }
        } catch {
            Logger.state.error("Chunked session recovery failed: \(error, privacy: .private)")
            outcome = SalvageOutcome(kind: .finalizeFailed(error.localizedDescription), chunkCount: chunkCount)
        }
        RecordingSentinel.delete(directory: sentinelDirectory)
        if let recovered {
            await presentCompletedTranscription(recovered)   // completion notice, rename + auto-summary
        }
        if case .transcribing = appState.phase { appState.phase = .idle }
        let message = RecoveryMessages.relaunchStopped(at: lastKnownAlive(sentinel), outcome: outcome)
        notifyCritical("Recording STOPPED", message)
        appState.raiseAppAlarm(.recordingStopped, message: message)
        captureClient.captureEnded()
    }

    /// When the crashed recording was last known to be alive: the STOPPED time must be that, never the
    /// recording's start (C9). L7: `lastAliveAt` / the end of the salvaged chunk — until the sentinel
    /// carries `lastAliveAt`, `startedAt` is only the placeholder.
    private func lastKnownAlive(_ sentinel: RecordingSentinel) -> Date {
        sentinel.startedAt
    }

    /// Chunks of `sessionId` on disk: completed in `session.json`, plus orphan WAVs not yet in it.
    private func chunksOnDisk(outputDir: URL, sessionId: String) -> Int {
        let completed = Set(SessionState.read(directory: outputDir)?.chunks.map(\.index) ?? [])
        return completed.count + CrashRecoveryPlanner.orphanChunks(
            outputDirectory: outputDir, sessionId: sessionId, completedIndices: completed).count
    }

    /// No live pipeline to salvage from (a relaunch re-attach): say what is on disk. "Nothing to
    /// salvage" would be false when chunks are there — they are kept, just not transcribed (§7.4 P6).
    private func unsalvagedOutcome(sentinel: RecordingSentinel?, why: String) -> SalvageOutcome {
        guard let sentinel else { return SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0) }
        let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        let count = chunksOnDisk(outputDir: outputDir, sessionId: stripSegmentSuffix(sentinel.systemAudioPath))
        return count > 0
            ? SalvageOutcome(kind: .finalizeFailed(why), chunkCount: count)
            : SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0)
    }

    /// The engines a launch recovery transcribes with: the injected factory (tests), else the runner's.
    private func prepareEngines(config: Config) throws -> (any TranscriptionEngine, (any DiarizationProvider)?) {
        if let engineFactory { return try engineFactory(config) }
        let prepared = try transcriptionRunner.prepareEngine(config: config)
        return (prepared.transcriber, prepared.diarizer)
    }

    /// Best-effort finalize a live chunked session being abandoned after an unrecoverable crash, so
    /// chunks already transcribed to session.json become a real transcript instead of being silently
    /// discarded (council F3). The give-up branch returns before the normal orphan re-ingestion, so
    /// it passes reingestOrphan: true to reclaim the in-progress chunk first.
    private func finalizeAbandonedSession(
        sentinel: RecordingSentinel,
        reingestOrphan: Bool
    ) async -> SalvageOutcome {
        guard let processor = transcriptionRunner.chunkProcessor else {
            transcriptionRunner.teardownChunkedPipeline()
            return unsalvagedOutcome(sentinel: sentinel, why: "transcription was not running in this session")
        }
        let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        transcriptionRunner.stopChunkRotation()

        if reingestOrphan, let rotator = transcriptionRunner.chunkRotator {
            _ = reingestOrphanChunk(rotator: rotator, processor: processor, outputDir: outputDir)
        }

        await processor.awaitAllProcessed()
        let sessionState = await processor.getSessionState()
        return await salvageAbandonedSession(sessionState: sessionState, outputDir: outputDir)
    }

    /// The salvage decision + execution half of `finalizeAbandonedSession`, split out verbatim
    /// behind an internal seam: the `!chunks.isEmpty` guard, provenance stamping, and the
    /// teardown-on-empty path are unit-testable with a crafted `SessionState` — the wrapper above
    /// requires a live `chunkProcessor`, which tests don't have.
    @discardableResult
    func salvageAbandonedSession(sessionState: SessionState, outputDir: URL) async -> SalvageOutcome {
        var sessionState = sessionState
        guard !sessionState.chunks.isEmpty else {
            transcriptionRunner.teardownChunkedPipeline()
            return SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0)
        }
        sessionState.provenance = await captureClient.finalizeSessionDiagnostics(
            sessionId: sessionState.sessionId,
            engine: configManager.config.engine.rawValue,
            recordingDirectory: outputDir
        )
        let kind: SalvageOutcome.Kind
        do {
            let result = try await transcriptionRunner.finalize(
                sessionState: sessionState, outputDirectory: outputDir, config: configManager.config
            )
            appState.lastJsonPath = result.jsonPath.path
            appState.lastTranscriptPath = result.jsonPath.path
            Logger.state.info("Salvaged abandoned chunked session → \(result.jsonPath.lastPathComponent, privacy: .sensitive)")
            kind = .transcriptWritten(result.jsonPath)
        } catch {
            // Reported, not swallowed (§7.4 P6): the chunks stay on disk, untranscribed.
            Logger.state.error("Salvage finalize failed: \(error, privacy: .private)")
            kind = .finalizeFailed(error.localizedDescription)
        }
        transcriptionRunner.teardownChunkedPipeline()
        return SalvageOutcome(kind: kind, chunkCount: sessionState.chunks.count)
    }

    // MARK: - Shared steps (deduplicated from MenuView)

    /// The post-transcription success sequence, previously duplicated verbatim in both the chunked
    /// and fallback branches of `stopRecording`: publish the transcript paths, return to idle,
    /// notify, then hand off to the rename dialog + auto-summary.
    private func presentCompletedTranscription(_ result: TranscriptionResult) async {
        appState.lastJsonPath = result.jsonPath.path
        appState.lastTranscriptPath = result.jsonPath.path
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
        // Whether the session is still ours to finish. `.idle` was deliberately deferred past the
        // async read (setting it first let a new recording start mid-read), but deferring opens the
        // mirror-image risk: the main actor is free during the suspension, so a crash handler or a
        // newly started session may legitimately have moved the phase on. Guarding only the `.idle`
        // assignment protects the wrong thing — the intrusive part is `presentTranscript`, which
        // would open the rename dialog on top of a live recording.
        var sessionStillOurs = false
        if case .transcribing = appState.phase {
            appState.phase = .idle
            sessionStillOurs = true
        }
        if anomalies > 0 {
            Logger.state.error(
                "Completed transcript carries \(anomalies, privacy: .public) capture anomalies — surfacing to the user"
            )
        }
        // The notification is passive, so it always fires: the transcript IS finished, and staying
        // silent about it would be the bigger failure.
        notify(
            CaptureQualityNotice.completionTitle(anomalyCount: anomalies),
            CaptureQualityNotice.completionBody(
                fileName: result.jsonPath.lastPathComponent, anomalyCount: anomalies)
        )
        guard sessionStillOurs else {
            // `lastJsonPath` is already set, so the transcript stays reachable from the menu — it is
            // only the modal presentation that is skipped.
            Logger.state.warning(
                "Recording state advanced while finishing the previous transcript — skipping the rename dialog so it cannot open over a live session"
            )
            return
        }
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

extension RecordingCoordinator: RecordingMicrophoneObserver {
    public func recordingMicrophoneChanged(to device: String??) {
        if case .some(let id) = device {
            helperMicKnown = true
            helperMicId = id
        } else {
            helperMicKnown = false
            helperMicId = nil
        }
    }
}
