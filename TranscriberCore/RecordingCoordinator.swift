import CoreGraphics
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
    let appState: AppState
    let captureClient: any RecordingCaptureClient
    let transcriptionRunner: TranscriptionRunner
    private let configManager: ConfigManager
    /// Test-only override for where the crash sentinel lives; nil = the real app-support path.
    let sentinelDirectory: URL?
    /// Post a normal user notification: (title, body).
    let notify: @MainActor (String, String) -> Void
    /// Post a critical alert (floating panel + critical notification): (title, body).
    private let notifyCritical: @MainActor (String, String) -> Void
    /// Present a completed transcript — rename dialog, then auto-summary: (jsonPath, config).
    private let presentTranscript: @MainActor (URL, Config) -> Void
    /// The helper found the tap running without its System Audio Recording permission (#220): the
    /// app opens its repair window. Injected because Core can't present AppKit windows.
    /// Returns whether the repair window actually presented: when it did not, the alarm window must.
    private let onSystemAudioPermissionDenied: @MainActor () async -> Bool
    /// Present the alarm UI (floating window + notification): (the DUE alarms — the ones the per-kind
    /// notify floor lets present now, oldest first; the kinds that are new since the last presentation).
    /// Called only when something is due.
    private let presentAlarmsUI: @MainActor ([ActiveAlarm], [AlarmKind]) -> Void
    /// Post one alarm's notification only — no window (the repair window may still open).
    private let notifyAlarm: @MainActor (ActiveAlarm) -> Void

    // MARK: - Alarm state (§6)

    /// How often the helper's alarm state is pulled while recording (§6.2). Tests shorten it.
    var statusPollInterval: Duration = .seconds(5)
    private var statusPoll: Task<Void, Never>?
    /// Consecutive `captureStatus` polls that got no answer; 3 raise `helperUnresponsive` (§8.13).
    private var missedPolls = 0
    /// Consecutive polls answering `isCapturing == false`; 2 take the crash-recovery path.
    private var notCapturingPolls = 0
    /// The kinds the last `presentAlarms` saw, so a kind is "new" only once per appearance. Internal for tests.
    private(set) var presentedKinds: Set<AlarmKind> = []
    /// The presenter's cadence while NOT recording (§6.3 "every 2 min while any alarm is active"): only
    /// while an alarm is active (one that outlives a recording) — no timer at all otherwise, so an idle
    /// app with nothing to say has zero wakeups. Tests shorten it.
    var idleRealarmInterval: Duration = .seconds(AlarmRealarmPolicy.notifyInterval)
    private var idleRealarm: Task<Void, Never>?
    /// Which idle presenter task is current: a replaced (cancelled) one must not clear its successor.
    private var idleRealarmGeneration = 0
    /// Presentations of each kind while idle: drives the idle backoff. Continues across a recording
    /// (mid-call presentations don't count); a NEW raise starts its own (L round 4, item 9).
    private var idleNotifications: [AlarmKind: Int] = [:]
    /// New permission kinds handed to the repair window, awaiting whether it presented (L round 4).
    private var pendingRepairKinds: Set<AlarmKind> = []
    /// How long a new permission alarm waits for the repair path's answer before its own notification
    /// goes out (L round 5): a macOS prompt takes ~10 s, and an unbounded permission refresh can hang.
    var repairOutcomeCap: Duration = .seconds(3)
    /// Internal for tests.
    var idleRealarmActive: Bool { idleRealarm != nil }

    // MARK: - Deadlines (§8.8)

    /// One deadline for the WHOLE start (addendum): the pre-flight lookup, then the helper's start (the
    /// client's own bounds are drain 3 s + configure 3 s + start 15 s, 21 s at worst). At the deadline the user
    /// is told at once; `isStartInFlight` is then held through the bounded stop that follows
    /// (`helperStopDeadline`), so at worst it is held for this plus that — never by a stalled audio system
    /// indefinitely (L9 review 47). Every §8.8 deadline counts awake time (`SuspendingClock`, L10 review 56).
    /// Tests shorten it.
    var startDeadline: Duration = .seconds(30)
    /// The user's Stop, a margin above the client's own 20 s: on timeout the session is salvaged from disk
    /// and the user told so, never left on "Finishing…" (council B-I1). Tests shorten it.
    var stopDeadline: Duration = .seconds(25)
    /// The pre-flight IOKit / CoreAudio HAL lookups (#193: lid closed, built-in mic). Synchronous, and a
    /// HAL daemon restart or a sleep/wake transition can stall them — run detached, under the start's
    /// deadline. A seam so tests can stall it.
    var preflight: @Sendable (String?) -> (lidClosed: Bool, builtInMic: Bool) = { deviceId in
        (ClamshellMicGuard.isLidClosed(), ClamshellMicGuard.isBuiltInMicSelected(deviceId: deviceId))
    }

    // MARK: - Sleep, wake, power-off, quit (§8.10)

    /// When the Mac went to sleep mid-recording: the wake records the interval as a capture gap. Cleared when
    /// the recording ends, which then delivers the helper's "wake" itself (L10 review 57).
    var sleptAt: Date?
    /// The "sleep" delivery to the helper: the "wake" waits for it, so the helper's sleep-time
    /// `cancelAll()` is always paired with its wake-time `trigger(.wake)` (H7).
    var sleepDelivery: Task<Void, Never>?
    /// A lost `didWake` must not leave app-side monitoring off for good (L10 review 55): armed at every sleep,
    /// it runs an implicit wake after `lostWakeTimeout` of AWAKE time (the clock does not count the sleep).
    var lostWakeWatchdog: Task<Void, Never>?
    var lostWakeTimeout: Duration = .seconds(30)
    /// The watchdog's clock: awake time. Tests drive it.
    var wakeWatchdogClock: any Clock<Duration> = SuspendingClock()
    /// Whether the Mac is FULLY awake — its main display on (L review 104). A DarkWake or a Power Nap is awake time
    /// with the display asleep: the watchdog's clock runs, yet the real wake has not happened. Tests set it.
    var displayIsAwake: @MainActor () -> Bool = { CGDisplayIsAsleep(CGMainDisplayID()) == 0 }
    /// How long the watchdog keeps re-arming while the Mac is awake but dark: the helper's DarkWake bound (H2).
    var darkWakeCap: Duration = .seconds(300)
    /// Where the watchdog's implicit wake ended the sleep's gap: a REAL didWake after it, with no sleep in between,
    /// records the rest of the sleep and restarts monitoring again — never swallowed (L review 104).
    var implicitWakeAt: Date?
    /// `ProcessInfo` activity that keeps the Mac from idle-sleeping from a recording's start until its
    /// transcript is finished — every phase but `.idle` (L10 review 59). Follows the phase, so every path in
    /// and out is covered. A lid close or a user sleep still sleeps: that is the user's call — recorded as a
    /// gap, not fought.
    var idleSleepActivity: NSObjectProtocol?
    /// Internal for tests.
    var preventsIdleSleep: Bool { idleSleepActivity != nil }
    /// The user's Quit stops the recording within this (at most 30 s, L10 review 60). Tests shorten it.
    var quitStopBound: Duration = TerminationPolicy.userQuitBound
    /// A user Quit still stopping after this says so (L10 review 60). Tests shorten it.
    var quitFeedbackDelay: Duration = .seconds(2)
    /// The user's Quit is stopping the recording: the menu says "Quitting…".
    public internal(set) var isQuitting = false
    /// The bound on the live-log flush at every exit (L review 96). Tests shorten it.
    var evidenceFlushBound: Duration = .seconds(1)
    /// The termination preparation running, if any: a second request (`willPowerOff` and the quit event, or
    /// two quit events) joins it instead of stopping twice.
    var terminationPrep: Task<Void, Never>?

    // MARK: - Sentinel liveness and relaunch (§8.3, §8.9)

    /// How often the sentinel's `lastAliveAt` is refreshed while recording (also at every rotation). A
    /// relaunch within `RelaunchDecision.resumeWindow` of it resumes the session. Tests shorten it.
    var aliveRefreshInterval: Duration = .seconds(60)
    private var aliveTimer: Task<Void, Never>?
    /// A retry of the pending sessions was asked for (a volume mounted, the Mac woke) while busy: it runs
    /// when the app is next idle. No timer: zero idle wakeups (L follow-up 35).
    var retryPendingWhenIdle = false
    /// Launch recovery and every pending-session retry run one at a time, under this one gate (L review 83):
    /// a retry during launch recovery would stop the crashed app's live helper as a "stray", or overlap two
    /// salvages. A retry asked for while it is held runs once it is released (and the app is idle).
    var recoveryGateHeld: Bool
    /// The gate is held for launch recovery from the start (L review 131): no wake or mount retry can beat it to a
    /// crashed app's live helper. `recoverAtLaunch` takes it over, then releases it.
    private var gateReservedForLaunch: Bool
    /// Pending sessions whose folder scan timed out this pass: waiting, and said so, until the next event reads their
    /// folder again (L review 127).
    private var foldersNotAnswering: Set<String> = []
    /// The `recordingStopped` messages of one recovery pass, said as ONE row at its end (L review 90); nil
    /// outside a pass.
    private var stoppedBatch: (recovered: [String], other: [String])?
    /// The bound on the free-space read at a rotation (L11 review 70): a hung volume skips that rotation's
    /// check, never the UI. Tests shorten it.
    var rotationDiskReadDeadline: Duration = .seconds(2)
    /// The disk check of the latest rotation, off the main actor; an older one that lands later is ignored.
    private var rotationDiskCheck: Task<Void, Never>?
    private var rotationDiskCheckGeneration = 0
    /// The bound on a helper stop that ends a capture on a failure or relaunch path (§8.6). Tests shorten it.
    var helperStopDeadline: Duration = .seconds(20)

    // MARK: - Restart confirmation (§8.4, §8.5)

    /// How long the restarted capture must deliver frames — with no newer crash and no mic
    /// NotDelivering alarm — before the retry streak resets (L9). Tests set it.
    public var recoveryConfirmationSeconds: TimeInterval = 60
    /// The confirmation window's clock: AWAKE time (L review 117) — a sleep inside the window never shortens it.
    /// Tests drive it.
    var recoveryConfirmationClock: any Clock<Duration> = SuspendingClock()
    /// A restart is waiting for the new helper's first mic frames before it says "Resumed".
    var awaitingRecoveryFrames = false
    /// When the restarted capture delivered its first mic frames: the confirmation window's start.
    var recoveryFramesAt: Date?
    /// The last time a snapshot carried `micNotDelivering`: inside the window it voids the confirmation.
    private var lastMicAlarmAt: Date?
    /// The awaited restart is a relaunch's resume: audio between the crash and the relaunch was lost,
    /// and "Resumed" says so (the `recordingResumedWithGap` alarm states the gap exactly).
    var restartLostAudio = false
    /// Only a relaunch's resume awaits frames before the phase is `.recording`: set there before its
    /// `start()`, cleared when the capture is up. Nothing else accepts frames outside a recording (L2/L4
    /// fix round 2, item 1).
    private var acceptFramesBeforeRecording = false
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
    /// A crash reported while a recovery was in flight (L1 fix round 1): queued, never a second
    /// concurrent recovery. Run after a successful restart — unless the helper turns out to be
    /// capturing — and dropped when the recording ends.
    private var pendingCrash = false
    /// `handleXPCCrash` is running (its recoveries, and the check between them).
    private var crashHandlingActive = false
    /// True while stopRecording() is running (it suspends on the helper's stop). A second Stop in that
    /// window — a double-tap, or a future programmatic caller — is ignored rather than reaching the
    /// helper and the transcription pipeline twice. Internal for tests.
    var stopInFlight = false
    /// A recording start is in flight: announced by the UI the moment its dialog commits (no main-actor
    /// turn in between counts as idle — L round 7), or running in `startRecording`, whatever the
    /// outcome. The phase is still `.idle` meanwhile, and a crash-protection hand-over (an exit) must
    /// wait; the Record control is disabled (§8.6, mirrors `stopInFlight`).
    /// The relaunch probing the helper — its ping, and the stops it may need — counts too (L review 112): Record is
    /// disabled until the helper's state is settled.
    public var isStartInFlight: Bool { startAnnounced || startRunning || relaunchProbing }
    /// A start that is not the relaunch's own: what every relaunch step yields to after an await (L reviews 38,
    /// 112, 129).
    var userStartInFlight: Bool { startAnnounced || startRunning }
    private var relaunchProbing = false
    private var startAnnounced = false
    private var startRunning = false
    /// A start refused because the helper is busy with an earlier capture: the pending retry runs once it is over.
    private var retryAfterStart = false
    /// The helper crashed (or failed fatally) while a start awaited it: the phase was still `.idle`, and
    /// the client reports a crash once per capture generation, so dropping it would leave a dead
    /// recording. Handled as soon as the recording is up; moot if the start fails.
    private(set) var crashDuringStart = false

    /// The UI committed to a Start (the session dialog closed): in flight from this very turn. The
    /// caller's Task always reaches `startRecording`, which takes it over at its first line — even
    /// when it then declines to start.
    public func announceStart() { startAnnounced = true }
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
    /// Free bytes on the volume holding a folder (§8.7); nil = unknown. Injected so tests never read the
    /// machine's real disk. `@Sendable`: the start reads it off the main actor (L follow-up 33).
    private let freeBytesProvider: @Sendable (URL) -> Int?

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
        onSystemAudioPermissionDenied: @escaping @MainActor () async -> Bool = { false },
        presentAlarmsUI: @escaping @MainActor ([ActiveAlarm], [AlarmKind]) -> Void = { _, _ in },
        notifyAlarm: @escaping @MainActor (ActiveAlarm) -> Void = { _ in },
        engineFactory: (@MainActor (Config) throws -> (any TranscriptionEngine, (any DiarizationProvider)?))? = nil,
        recordingMicrophone: RecordingMicrophone = .shared,
        freeBytesProvider: @escaping @Sendable (URL) -> Int? = { DiskSpaceCheck.freeBytes(at: $0) },
        launchRecoveryPending: Bool = true
    ) {
        recoveryGateHeld = launchRecoveryPending
        gateReservedForLaunch = launchRecoveryPending
        self.freeBytesProvider = freeBytesProvider
        self.onSystemAudioPermissionDenied = onSystemAudioPermissionDenied
        self.presentAlarmsUI = presentAlarmsUI
        self.notifyAlarm = notifyAlarm
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
        trackIdleSleepActivity()
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
        startAnnounced = false   // taken over from here
        // One start at a time: the phase is still `.idle` while the first awaits the helper, so the
        // isIdle guard below alone let a second start through (L round 7). The loser changes nothing.
        guard !startRunning else {
            Logger.state.info("A recording start is already in flight — ignoring a second one")
            return
        }
        startRunning = true
        defer {
            startRunning = false
            // A crash reported during this start — even during its failure path's helper stop — is this
            // start's, handled or moot by now: never inherited (L follow-up 29).
            crashDuringStart = false
            if retryAfterStart {
                retryAfterStart = false
                Task { await self.retryPendingSessions() }
            }
        }
        Logger.state.info("Recording started — session: \(sessionName, privacy: .sensitive)")
        appState.errorMessage = nil
        // Every await below takes what is left of this one deadline (§8.8, addendum), in awake time.
        let startBy = SuspendingClock.now + startDeadline

        // Pre-flight (#193): the built-in mic stays the default input device — and keeps delivering
        // full-rate buffers of exact digital zero — while the lid is closed. Warn BEFORE capture
        // starts, not only via the live exact-zero detector once the meeting is already underway.
        // Non-blocking: recording proceeds either way, exactly like every other interruption banner.
        // The lookups are synchronous IOKit / CoreAudio HAL calls: detached, so a stall never blocks the
        // main actor, and bounded, so a stall ends the start honestly instead of holding it forever.
        // The recording folder is read in its OWN detached task with its own short bound, concurrently (L
        // review 74): a hung network share must not freeze the UI (L follow-up 33), and must be named as the
        // folder's problem, never the audio system's.
        let preflight = self.preflight, freeBytesProvider = self.freeBytesProvider, probe = folderProbe
        let config = configManager.config
        let recordingDirectory = URL(fileURLWithPath: config.recordingDirectory)
        let folderBound = min(folderReadDeadline, max(.milliseconds(1), startBy - SuspendingClock.now))
        async let folderRead = readOffMain("start: recording folder", folder: recordingDirectory, bound: folderBound) {
            let status = Self.folderStatus(recordingDirectory, probe: probe)
            return (status, status == .reachable ? freeBytesProvider(Self.nearestExistingDirectory(recordingDirectory, probe: probe)) : nil)
        }
        let devices: (lidClosed: Bool, builtInMic: Bool)?
        do {
            devices = try await withDeadline(seconds: Self.seconds(until: startBy), label: "start: pre-flight") {
                await Task.detached { preflight(microphoneDeviceId) }.value
            }
        } catch {
            devices = nil
        }
        let folder = await folderRead
        // Re-entrancy guard: the await above is a genuine suspension point (unlike the two
        // synchronous IOKit/CoreAudio calls it replaced), so a second startRecording call fired
        // during it — e.g. a double-tap of the record control before the UI disables it — must not
        // race this one into writing a second sentinel / starting a second capture. Same
        // "bail if the state moved" pattern already used by the callback guards below. Checked
        // BEFORE the warning is set, so a call that loses the race never shows a banner for a
        // recording it isn't the one driving.
        guard appState.isIdle else { return }
        // Before the sentinel and the helper, and before any banner: nothing of this recording exists yet.
        // The recording folder is named as the cause first, before any disk verdict (L follow-up 32) — the
        // user copy names the folder, never a meeting.
        let folderName = abbreviatedDisplayPath(config.recordingDirectory)
        guard let (folderStatus, freeBytes) = folder else {
            Logger.state.error("Recording not started: the recording folder did not answer")
            refuseStart("Parley couldn’t reach the recording folder — is its drive or network share available? (\(folderName))")
            return
        }
        switch folderStatus {
        case .reachable:
            break
        case .unreachable:
            Logger.state.error("Recording not started: the recording folder is unreachable")
            refuseStart("The recording folder isn’t reachable — is its drive connected? (\(folderName))")
            return
        case .notWritable:
            Logger.state.error("Recording not started: the recording folder is not writable")
            refuseStart("Parley can’t write to the recording folder — check its permissions (\(folderName)).")
            return
        }
        guard let (lidClosed, isBuiltInMic) = devices else {
            Logger.state.error("Recording not started: the pre-flight audio-device lookup did not answer")
            reportUnresponsiveStart()
            return
        }
        // §8.7: never start what the disk cannot hold — two chunks plus headroom. Read on the folder's
        // nearest existing ancestor: a recording folder not created yet is still checked, never skipped.
        let free = freeBytes ?? .max
        guard DiskSpaceCheck.canStart(freeBytes: free, chunkMinutes: config.validatedChunkDuration) else {
            Logger.state.error("Recording not started: \(free / 1_000_000, privacy: .public) MB free")
            refuseStart(DiskSpaceCheck.message(freeBytes: free, chunkMinutes: config.validatedChunkDuration))
            return
        }
        if ClamshellMicGuard.shouldWarn(lidClosed: lidClosed, isBuiltInMic: isBuiltInMic) {
            appState.interruptionWarning = ClamshellMicGuard.warningMessage
        }

        let naming = Self.startNaming(sessionName: sessionName, now: Date())

        let outputDir = URL(fileURLWithPath: config.recordingDirectory)
            .appendingPathComponent(naming.dayDir)

        // A restart from an earlier recording that never saw frames must not say "Resumed" for this one,
        // not even for frames this helper reports during `start()` (fix round 2, item 1).
        resetRecoveryConfirmation()
        // Wired before the helper starts, so nothing it reports in its first seconds is lost.
        wireCaptureCallbacks()
        crashDuringStart = false
        // Set once the helper's capture is running: every failure after that stops it (§8.6).
        var captureStarted = false
        // The helper was asked to start: a start that timed out may still commit, so it is stopped too.
        var helperStartIssued = false
        // The mic marked before this start (a held session's, say): put back if the helper was busy with it.
        var micBefore: String?? = nil
        // What this start wrote to the slot: held from this copy if the slot cannot be read back (L review 132).
        var startedSentinel: RecordingSentinel?

        do {
            let sentinel = RecordingSentinel(
                startedAt: Date(),
                sessionName: naming.sanitized.isEmpty ? "Recording" : sessionName,
                systemAudioPath: outputDir.appendingPathComponent(naming.baseName + ".wav").path,
                micAudioPath: outputDir.appendingPathComponent(naming.baseName + "_mic.wav").path,
                micDeviceUID: microphoneDeviceId,
                segment: 1,
                chunkIndex: 0,
                lastAliveAt: Date(),
                bootSessionUUID: BootSession.currentUUID(),
                // A Quit already under way: whatever this start leaves behind is salvage-only (L review 105).
                stopping: isQuitting
            )
            try RecordingSentinel.write(sentinel, directory: sentinelDirectory)
            startedSentinel = sentinel

            // Before the helper opens the mic, so no meter opens it meanwhile (#192).
            micBefore = recordingMicrophone.current
            setHelperMic(microphoneDeviceId)
            helperStartIssued = true
            let baseName = naming.baseName, sessionId = naming.chunkBaseName
            let source = config.systemAudioSource, options = CaptureOptions(config: config)
            // Bounded by what is left of the start's deadline; a start that answers later changes nothing.
            try await bounded("start", seconds: Self.seconds(until: startBy)) {
                try await self.startHelper(outputDirectory: outputDir, baseName: baseName, microphoneDeviceId: microphoneDeviceId,
                                           systemAudioSource: source, options: options, sessionId: sessionId)
            }
            captureStarted = true

            try transcriptionRunner.setupChunkedPipeline(
                captureClient: captureClient,
                outputDirectory: outputDir,
                sessionBaseName: naming.chunkBaseName,
                config: config
            )
            transcriptionRunner.startChunkRotation()
            wirePipelineHooks()

            appState.phase = .recording(since: Date())
            startStatusPoll()
            xpcRetryCount = 0
            lastCrashAt = nil
            recoveryInFlight = false
            stopRequestedDuringRecovery = false
            presentCarriedAlarmsAtRecordingStart()
            if crashDuringStart {
                crashDuringStart = false
                Logger.state.warning("The helper crashed while the recording was starting — crash recovery now")
                Task {
                    guard self.appState.isRecording else { return }
                    await self.handleXPCCrash()
                }
            }
        } catch {
            crashDuringStart = false   // moot: this failure path ends the recording
            // Said first, at the deadline — not after the stop below, which may take its own bound (L9 review
            // 47). The start stays in flight until that stop returns: no new Start races it. The helper's own
            // replies are said in words, never as the wire text (L review 91).
            let reply = Self.helperReply(error.localizedDescription)
            switch reply {
            case _ where error is CaptureCallTimeout, .startTimedOut:
                reportUnresponsiveStart()
            case .startCancelled:
                reportFailedStart("Parley couldn’t start recording — the start was cancelled.")
            case .alreadyCapturing:
                // An earlier capture the helper has not let go of (a held session's): the pending retry stops
                // and finishes it — kicked once this start is over.
                reportFailedStart("Parley couldn’t start recording — the capture helper is still busy with an earlier recording.")
                retryAfterStart = true
            default:
                reportFailedStart(error.localizedDescription)
            }
            // The helper is capturing (a later step failed), or its start timed out and may still commit:
            // stop it — bounded — BEFORE the mic marker is released, so no meter opens the mic the helper
            // still holds (#192, §8.6). A stop during a start aborts it (H2): no helper is left capturing.
            let helperLetGo = await stopAfterFailedStart(captureStarted: captureStarted, startIssued: helperStartIssued,
                                                         error: error, label: "stop after failed start")
            captureClient.captureEnded()   // the recording never began: disarm crash detection (C1)
            if helperLetGo {
                // A busy helper still holds the mic of the capture it is busy with: that marker stays (#192).
                if reply == .alreadyCapturing { restoreHelperMic(micBefore) } else { clearHelperMic() }
                RecordingSentinel.delete(directory: sentinelDirectory)
                // No recording exists: no evidence of one either — never an orphan live log (L11 review 68).
                captureClient.discardSessionEvidence(sessionId: naming.chunkBaseName, directory: outputDir)
            } else {
                // The helper may still be capturing, and hold the mic (L follow-up 27): HELD (L review 81) —
                // salvage-only, out of the slot the next Start writes, the mic kept marked — and finished once
                // the helper's stop says it let go. From the slot, or — it cannot be read back — from what this start
                // wrote there (L review 132): never a marked mic with nothing left to release it.
                let slot = RecordingSentinel.read(directory: sentinelDirectory)
                if slot == nil { Logger.state.error("A failed start's recovery file cannot be read back — holding its session from the start's own copy") }
                Logger.state.error("A failed start left the capture helper unanswered — holding its session")
                if let held = slot ?? startedSentinel {
                    holdForHelper(held, message: "Parley couldn’t stop the capture of the recording that failed to start — its audio is kept, and Parley will finish it once the capture helper lets go.")
                } else {
                    reportStopped("Parley couldn’t stop the capture of a recording that failed to start, and has no record of it — check the recordings folder.", recovered: false)
                }
            }
        }
    }

    /// A start refused before anything began: said in the app as well as in a notification, so it is seen
    /// with notifications turned off (L follow-up 34).
    private func refuseStart(_ message: String) {
        appState.errorMessage = message
        notify("Recording not started", message)
    }

    /// The start ran out of its deadline: the audio system, not the user, is stuck — said plainly.
    private func reportUnresponsiveStart() {
        reportFailedStart("Parley couldn’t start recording — the audio system didn’t respond.")
    }

    private func reportFailedStart(_ message: String) {
        appState.errorMessage = message
        notify("Recording Failed", message)
    }

    /// Put the recording-mic marker back as it was (`.none`: nothing marked).
    private func restoreHelperMic(_ marked: String??) {
        if case .some(let id) = marked { setHelperMic(id) } else { clearHelperMic() }
    }

    /// What is left until `deadline`, in awake seconds (never zero: a spent deadline still times out at once).
    static func seconds(until deadline: SuspendingClock.Instant) -> Double {
        max(0.001, seconds(deadline - .now))
    }

    static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    /// A helper call bounded at the coordinator (§8.8), on top of the client's own deadline: a
    /// `DeadlineError` is recorded as `xpcTimeout` and thrown as `CaptureCallTimeout`, whose wording is the
    /// user's. The body runs on after a timeout, but its completion changes nothing.
    func bounded<T: Sendable>(_ call: String, seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await withDeadline(seconds: seconds, label: call, body)
        } catch DeadlineError.timedOut {
            Logger.state.error("The capture helper did not answer \(call, privacy: .public) within \(seconds, privacy: .public) s")
            captureClient.record(.xpcTimeout, .anomaly, ["call": call])
            throw CaptureCallTimeout(call: call, seconds: seconds)
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
            Logger.state.error("Could not record the switched mic in the sentinel: \(error, privacy: .private)")
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
            // The user's Stop, already: a crash before the deferred stop runs is salvaged, never resumed.
            markSentinelStopping()
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
        // Read ONCE, before the stop: a successful stop deletes it, and the catch below must still know
        // where the session is (L6 fix round 1).
        let sentinel = RecordingSentinel.read(directory: sentinelDirectory)
        // BEFORE asking the helper (§8.8): a crash during the stop or its finalize must be salvaged at
        // relaunch, never resume a recording the user stopped.
        markSentinelStopping()
        // No rotation may race the helper's stop (council B-I3): the timer stops, and a rotation already in
        // flight completes — bounded, as the client bounds a rotate at 10 s — before the helper is asked.
        transcriptionRunner.stopChunkRotation()
        _ = try? await withDeadline(seconds: 10, label: "rotation before stop") { await self.awaitRotationInFlight() }
        var stoppedPaths: AudioPaths?
        do {
            // Bounded (§8.8): a helper that never answers is salvaged from disk in the catch below.
            let paths = try await bounded("stop", seconds: Self.seconds(stopDeadline)) { try await self.helperStop() }
            stoppedPaths = paths
            clearHelperMic()   // only now has the helper let go of the mic (#192)
            // The sentinel stays (marked stopping) until the transcript exists: a crash, force-quit or
            // power loss during finalize is still salvaged at the next launch (§8.8, council C-I7).

            appState.phase = .transcribing(progress: "Transcribing…")

            if let rotator = transcriptionRunner.chunkRotator,
               let processor = transcriptionRunner.chunkProcessor {
                // A rotation that timed out may have completed in the helper: the chunk it sealed is processed
                // from its own files (L9 review 46). The last chunk is the one the stop's reply NAMES, labelled
                // by its own index — never another chunk's (L review 113).
                let lastChunk = await rotator.lastChunkAtStop(systemPath: paths.systemAudio.path, micPath: paths.micAudio.path)
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
                // Only now, the transcript on disk, does the live log go (L review 97).
                captureClient.commitSessionDiagnostics(sessionId: sessionState.sessionId, directory: outputDir)
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
                // Off the main actor, bounded (L review 122): a folder that does not answer is said so, and kept.
                guard let recoverable = await readOffMain("stop: session folder", folder: sessionOutputDir, {
                    CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: sessionOutputDir, sessionId: sessionId)
                }) else { throw FolderNotAnswering() }
                if recoverable {
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
                    // A transcript, or nothing at all to keep: the live log goes (L review 97).
                    captureClient.commitSessionDiagnostics(sessionId: sessionId, directory: sessionOutputDir)
                } else {
                    // Genuine single-file input (non-chunked recording / legacy path).
                    let (systemAudio, micAudio) = Self.legacySingleFileInputs(
                        sentinel: sentinel, stoppedPaths: paths
                    )

                    // #95/council F6: the recovery path also drains diagnostics, flushes the
                    // anomaly-gated <sessionId>.diag.jsonl, and stamps capture_provenance (incl.
                    // recovered=true) — previously only the chunked branch did this.
                    let outputDir = systemAudio.deletingLastPathComponent()
                    // The session id without its `-N` segment: the id the evidence is bound to (L review 101).
                    let sid = stripSegmentSuffix(systemAudio.path)
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
                    captureClient.commitSessionDiagnostics(sessionId: sid, directory: outputDir)
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

            // Only now: the transcript exists (or there was nothing to write).
            RecordingSentinel.delete(directory: sentinelDirectory)
            transcriptionRunner.teardownChunkedPipeline()
        } catch {
            // Either the helper's stop failed, or (stop succeeded) finishing the transcript did.
            let stopSucceeded = stoppedPaths != nil
            // A stop that TIMED OUT may have left the helper capturing: drop the connection BEFORE the salvage
            // — the helper's invalidation handler stops and finalizes its capture — and only then release the
            // mic (L9 review 45). The sentinel stays marked `stopping` until the salvage below has run, so a
            // crash meanwhile is salvaged at relaunch. Any other stop failure (an XPC crash, a fatal failure)
            // means the helper has already gone.
            if !stopSucceeded, error is CaptureCallTimeout {
                Logger.state.error("The capture helper did not answer the stop — dropping the connection so it stops")
                captureClient.dropConnection()
            }
            clearHelperMic()
            // council FV2 defense-in-depth: if a live chunked pipeline still holds transcribed chunks,
            // salvage them into a transcript instead of discarding the session with a blind teardown.
            // A failed stop left the in-progress chunk unprocessed: re-ingest it (inside the first
            // chunk it IS the recording); after a successful stop it was already handed over.
            // Where the session is: the sentinel's, else the live pipeline's own (a sentinel deleted
            // mid-recording must not turn the salvage into "no recorded audio" — L round 5), else the
            // stopped capture's.
            let location = Self.sessionLocation(sentinel: sentinel, stoppedPaths: nil)
                ?? transcriptionRunner.chunkRotator?.sessionLocation
                ?? Self.sessionLocation(sentinel: nil, stoppedPaths: stoppedPaths)
            let outcome: SalvageOutcome
            if transcriptionRunner.chunkProcessor != nil, let location {
                outcome = await finalizeAbandonedSession(at: location, reingestOrphan: !stopSucceeded)
            } else {
                transcriptionRunner.teardownChunkedPipeline()
                outcome = await unsalvagedOutcome(at: location, why: error.localizedDescription)
            }
            finishSentinel(after: outcome, sentinel: sentinel)
            appState.errorMessage = error.localizedDescription
            // #155: this catch is the stop path's only signal to the user. It says what the salvage did and what is on
            // disk (§7.4 P6), and whether the stop itself failed or only the transcript. The recovery file goes with the
            // salvage — unless the folder did not answer: then it is kept, salvage-only, for when it does (L review 122).
            let body = stopSucceeded
                ? RecoveryMessages.transcriptionFailed(after: outcome, error: error.localizedDescription)
                : RecoveryMessages.stopFailed(after: outcome, error: error.localizedDescription)
            notifyCritical(RecoveryMessages.stopFailureTitle(after: outcome, stopSucceeded: stopSucceeded), body)
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
            Task { @MainActor in await self?.crashReported() }
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
            Task { @MainActor in await self?.crashReported() }
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

    /// A crash or fatal failure from the helper. While a start awaits it the phase is still `.idle`: the
    /// crash counts for that recording and is handled once it is up. Outside a recording: nothing.
    private func crashReported() async {
        guard appState.isRecording else {
            // A start in flight, or the relaunch probing a capture it may re-attach to (L review 124): the crash is
            // that recording's, handled once it is up.
            if startRunning || relaunchProbing { crashDuringStart = true }
            return
        }
        await handleXPCCrash()
    }

    /// Pull the helper's alarm state every `statusPollInterval` while recording (§6.2). Holds the
    /// coordinator only while polling, never across the sleep.
    func startStatusPoll() {
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
        // The sentinel's liveness rides along: every `aliveRefreshInterval` while recording (§8.3).
        aliveTimer?.cancel()
        aliveTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.aliveRefreshInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.appState.isRecording else { return }
                self.refreshSentinelLiveness()
            }
        }
    }

    /// Called on every path that ends a recording: the poll stops, and a restart still waiting for its
    /// first frames is dropped with it (fix round 2, item 1).
    func stopStatusPoll() {
        statusPoll?.cancel()
        statusPoll = nil
        aliveTimer?.cancel()
        aliveTimer = nil
        missedPolls = 0
        notCapturingPolls = 0
        resetRecoveryConfirmation()
    }

    /// Forget a restart's pending "Resumed" confirmation.
    private func resetRecoveryConfirmation() {
        awaitingRecoveryFrames = false
        recoveryFramesAt = nil
        lastMicAlarmAt = nil
        restartLostAudio = false
        acceptFramesBeforeRecording = false
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
                // NOT awaited inside the status-poll task: a Stop deferred during this restart cancels
                // the poll (`stopStatusPoll`), and the whole stop + finalize would then run cancelled —
                // AudioConcatenator's timeout sleep throws and the merged archive is skipped (fix round 2).
                Task {
                    guard self.appState.isRecording else { return }   // it ended meanwhile (L round 4)
                    await self.handleXPCCrash()
                }
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
    /// While not recording the idle backoff applies (2, 10, then 60 min; a past event once — owner
    /// ruling, fix round 2). `reshow`: kinds to present again now, window included, whatever their
    /// floor — without restarting their backoff (L round 4).
    func presentAlarms(now: Date = Date(), reshow: Set<AlarmKind> = []) {
        let active = appState.alarms.sorted
        let newKinds = active.map(\.kind).filter { !presentedKinds.contains($0) }
        presentedKinds = Set(active.map(\.kind))
        idleNotifications = idleNotifications.filter { presentedKinds.contains($0.key) }
        for kind in newKinds { idleNotifications[kind] = nil }   // a new raise starts its own backoff
        // A NEW permission kind goes to the repair window first; the alarm window steps in only if
        // that window does not present (L round 4, item 4).
        let toRepair = newKinds.filter(\.hasOwnRepairWindow)
        if !toRepair.isEmpty { presentThroughRepairWindow(toRepair) }
        let idle = !appState.isRecording
        let due = active.filter { alarm in
            if pendingRepairKinds.contains(alarm.kind) { return false }
            if reshow.contains(alarm.kind) { return true }
            guard idle else { return AlarmRealarmPolicy.shouldRenotify(alarm, now: now) }
            // While idle a newly raised kind presents at once, whatever its floor (L round 3); that
            // presentation is the first step of its backoff.
            return newKinds.contains(alarm.kind)
                || AlarmRealarmPolicy.shouldRenotifyWhileIdle(alarm, notificationsWhileIdle: idleNotifications[alarm.kind] ?? 0, now: now)
        }
        guard !due.isEmpty else { return }
        for alarm in due {
            appState.markNotified(alarm.kind, now: now)
            if idle { idleNotifications[alarm.kind, default: 0] += 1 }
        }
        let dueKinds = Set(due.map(\.kind))
        presentAlarmsUI(due, (newKinds + reshow).filter { dueKinds.contains($0) })
    }

    /// The repair window names the missing permission and fixes it, so a NEW permission alarm goes
    /// there first. When it does not present — nothing missing app-side (`remoteCantConfirm`, #220's
    /// "coreaudiod refuses although granted"), or its snooze — the alarm window presents it at once:
    /// never silent for 2 minutes mid-call. It counts as notified only once something was shown.
    private func presentThroughRepairWindow(_ kinds: [AlarmKind]) {
        pendingRepairKinds.formUnion(kinds)
        let answer = RepairAnswer()
        // The cap: no answer within `repairOutcomeCap` (a prompt, or a hung check) → the alarm's own
        // notification now — no window, the repair window may still open — and the normal cadence resumes.
        Task { [weak self] in
            guard let cap = self?.repairOutcomeCap else { return }
            try? await Task.sleep(for: cap)
            guard let self, !answer.arrived else { return }
            self.pendingRepairKinds.subtract(kinds)
            let now = Date()
            for alarm in kinds.compactMap({ self.appState.activeAlarms[$0] }) {
                self.appState.markNotified(alarm.kind, now: now)
                self.notifyAlarm(alarm)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            let presented = await self.onSystemAudioPermissionDenied()
            answer.arrived = true
            self.pendingRepairKinds.subtract(kinds)
            let alarms = kinds.compactMap { self.appState.activeAlarms[$0] }
            guard !alarms.isEmpty else { return }
            let now = Date()
            for alarm in alarms { self.appState.markNotified(alarm.kind, now: now) }
            if !presented { self.presentAlarmsUI(alarms, alarms.map(\.kind)) }
        }
    }

    /// Owner ruling (fix round 2, item 5): an alarm still active from before — crash protection off, an
    /// unacknowledged STOPPED — is presented again, at once, when a recording starts.
    /// Only live conditions: a past event was presented once and stays a row until acknowledged (L
    /// round 4, item 6). Their idle backoff continues after the recording (item 9).
    func presentCarriedAlarmsAtRecordingStart(now: Date = Date()) {
        let carried = Set(appState.alarms.sorted.map(\.kind).filter { !$0.isAcknowledgeable })
        guard !carried.isEmpty else { return }
        presentAlarms(now: now, reshow: carried)
    }

    /// (Re)starts or stops the idle presenter from the alarms and the phase, then re-evaluates on their
    /// next change (Observation: one outstanding registration, re-armed here only). While recording, the
    /// status poll presents instead. The timer sleeps until the next alarm is actually due (backoff:
    /// minutes to an hour), and there is none at all when nothing will ever be due again.
    private func updateIdleRealarm() {
        if !appState.isRecording {
            // An alarm raised while idle is presented AT ONCE, exactly once per raise (L round 3); a
            // cleared kind is forgotten, so its next raise is new again.
            let active = Set(appState.activeAlarms.keys)
            presentedKinds.formIntersection(active)
            if !active.isSubset(of: presentedKinds) { presentAlarms() }
        }
        idleRealarm?.cancel()
        idleRealarm = nil
        if !appState.isRecording, idleNextDelay() != nil {
            idleRealarmGeneration += 1
            let generation = idleRealarmGeneration
            idleRealarm = Task { [weak self] in
                while !Task.isCancelled {
                    guard let delay = self?.idleNextDelay() else { break }
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self else { return }
                    self.presentAlarms()
                }
                // Ended by itself (nothing more to say): let the next change start a fresh one.
                if !Task.isCancelled, let self, self.idleRealarmGeneration == generation { self.idleRealarm = nil }
            }
        }
        withObservationTracking {
            _ = appState.alarms
            _ = appState.phase
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIdleRealarm() }
        }
    }

    /// How long until an idle alarm is due, never sooner than `idleRealarmInterval`; nil when none will
    /// ever be (only past events already presented).
    private func idleNextDelay(now: Date = Date()) -> Duration? {
        let waits: [TimeInterval] = appState.alarms.sorted.compactMap { alarm in
            guard let last = alarm.lastNotifiedAt else { return 0 }
            if alarm.kind.isAcknowledgeable { return nil }
            let gap = AlarmRealarmPolicy.idleRenotifyInterval(afterNotifications: idleNotifications[alarm.kind] ?? 0)
            return max(0, last.addingTimeInterval(gap).timeIntervalSince(now))
        }
        guard let soonest = waits.min() else { return nil }
        return max(idleRealarmInterval, .seconds(soonest))
    }

    /// The new helper's frames clear the previous helper's DELIVERY alarms on that track (L2). After a
    /// restart, the first MIC frames are what "Recording Resumed" waits for (§8.4) — never `start()`
    /// returning — and they open the confirmation window that may reset the retry streak (L9).
    func noteFirstFrames(track: CaptureTrack, helperSessionId: String, now: Date = Date()) {
        // Only a relaunch's resume accepts frames before the phase is `.recording`.
        guard appState.isRecording || acceptFramesBeforeRecording else { return }
        appState.noteFirstFrames(track: track, helperSessionId: helperSessionId)
        presentAlarms(now: now)
        // A Stop pressed during the restart: the recording is ending — nothing "resumed" (item 2).
        guard track == .mic, awaitingRecoveryFrames, !stopRequestedDuringRecovery else { return }
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
        let window = recoveryConfirmationSeconds, clock = recoveryConfirmationClock
        Task { [weak self] in
            // Awake time (L review 117): the window's end is this clock's, for THIS window only.
            do { try await clock.sleep(for: .seconds(window)) } catch { return }
            self?.confirmRecoveryHealthy(windowOf: now)
        }
    }

    /// L9 / §8.5: the streak resets only after `recoveryConfirmationSeconds` of frames since the
    /// restart's first frame, with no newer crash and no mic NotDelivering alarm in that window.
    /// `windowOf`: the scheduled check — the window that began then has run its length in AWAKE time (L review
    /// 117); a later restart's window is never ended by an earlier one's check. Without it, the wall clock `now`.
    func confirmRecoveryHealthy(now: Date = Date(), windowOf scheduled: Date? = nil) {
        guard appState.isRecording, let since = recoveryFramesAt,
              scheduled.map({ $0 == since }) ?? (now.timeIntervalSince(since) >= recoveryConfirmationSeconds),
              lastCrashAt.map({ $0 <= since }) ?? true,
              lastMicAlarmAt.map({ $0 <= since }) ?? true,
              appState.activeAlarms[.micNotDelivering] == nil else { return }
        xpcRetryCount = 0
        recoveryFramesAt = nil
    }

    // MARK: - Crash recovery

    /// Internal (not private) so the crash-recovery decision paths are reachable from unit tests.
    /// Serialized (L1 fix round 1): a crash reported while a recovery is in flight — the restarted
    /// helper dying during its own `start()` — is queued and handled after that recovery restarts
    /// successfully (counting toward the cap), or dropped when it gives up. Two concurrent recoveries
    /// ended with a capturing helper, an idle app and detection off.
    func handleXPCCrash() async {
        // A stop's trailing interruption/invalidation lands while it is in flight: the stop path owns the
        // teardown (it re-ingests the orphan and salvages on failure). A restart now would race it (§8.6).
        guard !stopInFlight else {
            Logger.state.info("Crash handler yielding to a stop in flight")
            return
        }
        guard !crashHandlingActive else {
            Logger.state.warning("Crash reported while a recovery is in flight — queued")
            pendingCrash = true
            return
        }
        crashHandlingActive = true
        defer {
            crashHandlingActive = false
            pendingCrash = false
        }
        await recoverFromCrash()
        while pendingCrash && appState.isRecording {
            pendingCrash = false
            // A queued event may be a duplicate or stale report of the death just handled (an
            // interruption plus an invalidation, or a blip scored against the old `.ips`). Re-running
            // recovery on a capturing helper would fail its `start()` and end a healthy recording as
            // "Failed" (L round 5). Bounded: a helper that does not answer in 3 s (`.unknown`) is treated as
            // dead. `recoveryInFlight` is held across the check: a Stop pressed meanwhile takes the deferred
            // path instead of racing a restart (L round 7).
            recoveryInFlight = true
            let capturing = (try? await withDeadline(seconds: 3, label: "queued crash: captureState") {
                await self.helperCaptureState()
            }) == .capturing
            recoveryInFlight = false
            if stopRequestedDuringRecovery {
                stopRequestedDuringRecovery = false
                Logger.state.info("Honoring stop requested during the queued-crash check")
                await stopRecording()
                break
            }
            guard appState.isRecording, !stopInFlight else { break }
            if capturing {
                Logger.state.info("Queued crash event dropped — the helper is capturing (a duplicate or stale report)")
                continue
            }
            await recoverFromCrash()
        }
    }

    private func helperCaptureState() async -> HelperCaptureState { await captureClient.captureState() }
    /// The helper's stop, its paths discarded, for the bounded stops that only need the helper gone.
    func stopHelper() async throws { _ = try await helperStop() }
    /// The helper calls a bounded (`@Sendable`) body makes: main-actor methods, so the body never touches
    /// the client itself.
    private func helperStop() async throws -> AudioPaths { try await captureClient.stop() }
    private func startHelper(outputDirectory: URL, baseName: String, microphoneDeviceId: String?,
                             systemAudioSource: SystemAudioSource, options: CaptureOptions, sessionId: String) async throws {
        try await captureClient.start(outputDirectory: outputDirectory, baseName: baseName, microphoneDeviceId: microphoneDeviceId,
                                      systemAudioSource: systemAudioSource, options: options, sessionId: sessionId)
    }
    func awaitRotationInFlight() async { await transcriptionRunner.chunkRotator?.awaitRotationInFlight() }
    private func attributeHelperDrain(_ sessions: [(sessionId: String, directory: URL)]) async {
        await captureClient.attributeHelperDrain(toOneOf: sessions)
    }
    private func flushEvidence() async { await captureClient.flushEvidence() }

    /// Every queued live-log write reaches the disk before the process ends (L review 96) — bounded: a stuck disk
    /// never holds an exit longer than `evidenceFlushBound`.
    func flushEvidenceForExit() async {
        _ = try? await withDeadline(seconds: Self.seconds(evidenceFlushBound), label: "exit: evidence flush") { await self.flushEvidence() }
    }

    /// A bounded helper stop on a path that ends a capture (§8.6). True once the helper has let go: it
    /// stopped, or it answered that nothing was capturing. False when it did not stop — it timed out, or
    /// failed otherwise — and it may still be capturing and hold the mic. Never swallowed (L follow-up 27):
    /// every failure is logged `.error` and recorded (a timeout as `xpcTimeout`, by `bounded`).
    ///
    /// A timeout pulls the last lever (L9 review 45): the XPC connection is dropped, so the helper's
    /// invalidation handler stops and finalizes its capture. Still false — nothing confirmed it let go.
    ///
    /// "Refused: capture is starting or stopping" is a stop already under way in the helper (it ends within its
    /// own 6 s): asked again, shortly, within the same bound (L review 91) — never read as a helper that will not
    /// let go.
    private func boundedHelperStop(_ label: String) async -> Bool {
        let deadline = SuspendingClock.now + helperStopDeadline
        while true {
            do {
                try await bounded(label, seconds: Self.seconds(until: deadline)) { try await self.stopHelper() }
                return true
            } catch is CaptureCallTimeout {
                Logger.state.error("The capture helper did not stop (\(label, privacy: .public)) — it may still be capturing; dropping the connection")
                captureClient.dropConnection()
                return false
            } catch {
                switch Self.helperReply(error.localizedDescription) {
                case .notCapturing, .startCancelled:
                    return true   // nothing is capturing: it has let go
                case .stopping where SuspendingClock.now + stopReaskInterval < deadline:
                    Logger.state.info("The capture helper is already stopping (\(label, privacy: .public)) — asking again shortly")
                    try? await Task.sleep(for: stopReaskInterval)
                    continue
                default:
                    Logger.state.error("The capture helper's stop failed (\(label, privacy: .public)): \(error, privacy: .private)")
                    captureClient.record(.streamStopError, .anomaly, ["source": "app", "call": label, "error": error.localizedDescription])
                    return false
                }
            }
        }
    }

    /// How soon a stop the helper refused because it is already stopping is asked again (L review 91).
    var stopReaskInterval: Duration = .milliseconds(250)

    /// A start site failed (§8.6) — the recording's start, the crash restart, the relaunch's resume: the one
    /// rule for all three (L9 review 44). The helper's capture is running (a later step failed), or its start
    /// timed out and may still commit: stop it, bounded. True once the helper let go, or when it was never
    /// started; false when it may still be capturing.
    private func stopAfterFailedStart(captureStarted: Bool, startIssued: Bool, error: Error, label: String) async -> Bool {
        guard captureStarted || (startIssued && error is CaptureCallTimeout) else { return true }
        return await boundedHelperStop(label)
    }

    private func recoverFromCrash() async {
        // council FV2: serialize against a user Stop pressed mid-recovery. The defer clears both
        // flags on every exit so a deferred stop never leaks into the next recovery.
        recoveryInFlight = true
        // A restart whose helper would not stop may still hold the mic: it stays marked (L9 review 44).
        var keepMicMarked = false
        defer {
            recoveryInFlight = false
            stopRequestedDuringRecovery = false
            // Every give-up path ends the recording without stopRecording(); release the mic record.
            if appState.isIdle, !keepMicMarked { clearHelperMic() }
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
            captureClient.captureEnded()
            // No recovery file to restart from, but a live pipeline still knows its session: salvage it
            // there (the rotation stops, the pipeline is torn down) — never leave it running behind an idle
            // app (L follow-up 28).
            // What is said follows what was looked at (L review 87): the salvage's outcome when a pipeline knew
            // the session — never "no recovery data" beside a transcript it wrote — and no claim at all when
            // nothing could be looked at.
            if let location = transcriptionRunner.chunkRotator?.sessionLocation {
                let outcome = await finalizeAbandonedSession(at: location, reingestOrphan: true)
                appState.criticalError = RecoveryMessages.crashWithoutRecoveryFile(after: outcome)
                appState.phase = .idle
                stopStatusPoll()
                notifyCritical("Recording Failed", RecoveryMessages.recordingFailed(after: outcome))
            } else {
                transcriptionRunner.stopChunkRotation()
                transcriptionRunner.teardownChunkedPipeline()
                appState.criticalError = RecoveryMessages.crashWithoutRecoveryFileOrPipeline
                appState.phase = .idle
                stopStatusPoll()
                notifyCritical("Recording Failed", RecoveryMessages.crashWithoutRecoveryFileOrPipeline)
            }
            return
        }

        if decision.shouldGiveUp {
            // FIRST, before any await: disarm crash detection, so the dying helper's next interruption
            // is never read as a new crash while the salvage runs (L1 fix round 1).
            captureClient.captureEnded()
            Logger.state.error("All retries exhausted after \(self.xpcRetryCount) interruptions within the decay window")
            // council F3: salvage the live chunked session (re-ingesting the in-progress orphan,
            // since this branch returns before the normal re-ingestion below) so chunks already
            // transcribed aren't discarded with the session.
            let outcome = await finalizeAbandonedSession(at: Self.location(of: sentinel), reingestOrphan: true)
            appState.criticalError = "Recording failed — capture crashed repeatedly. " + RecoveryMessages.outcomeSentence(outcome)
            appState.phase = .idle
            stopStatusPoll()
            finishSentinel(after: outcome, sentinel: sentinel)
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
            let orphan = await reingestOrphanChunk(rotator: rotator, processor: processor, outputDir: outputDir)
            let plan = await rotator.recoverFromCrash()
            let restart = Self.liveRestartPlan(sentinel: sentinel, recoveryPlan: plan, outputDir: outputDir)
            baseName = restart.baseName
            newSentinel = restart.newSentinel
            Logger.state.info("Re-ingested orphan chunk \(orphan.index, privacy: .public) (\(orphan.baseName, privacy: .sensitive)); recovery continues at \(baseName, privacy: .sensitive)")
        } else {
            // No live pipeline (app-relaunch re-attach): there is no rotator to hand us a
            // collision-free index, so derive one directly. #135: name the restart capture in the
            // chunk-index namespace, never the legacy segment counter — the two namespaces can
            // collide. CrashRecoveryPlanner.planRestart owns the collision guard + naming
            // sequence, shared by every no-live-pipeline restart site (#170). Read off the main actor, bounded (L
            // review 122): a folder that does not answer cannot name a restart safely — the recording ends, kept.
            guard let restart = await readOffMain("crash restart: plan", folder: outputDir, {
                CrashRecoveryPlanner.planRestart(sentinel: sentinel, outputDirectory: outputDir)
            }) else {
                await endRecordingFolderNotAnswering(sentinel)
                return
            }
            baseName = restart.baseName
            newSentinel = restart.newSentinel
        }

        var startIssued = false, captureStarted = false
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
            startIssued = true
            try await captureClient.start(
                outputDirectory: outputDir,
                baseName: baseName,
                microphoneDeviceId: sentinel.micDeviceUID,
                systemAudioSource: configManager.config.systemAudioSource,
                options: CaptureOptions(config: configManager.config),
                sessionId: stripSegmentSuffix(sentinel.systemAudioPath)
            )
            captureStarted = true
            newSentinel.lastAliveAt = Date()
            // A Stop deferred during this restart already marked the sentinel; the rewrite keeps the mark.
            newSentinel.stopping = newSentinel.stopping || stopRequestedDuringRecovery
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
            // Re-checked after the await (§8.6): nothing else ends a recording mid-restart today, but a
            // restart must never announce itself for a recording that is no longer running.
            guard appState.isRecording, !stopInFlight else {
                // Unreachable: a restart is serialized under `recoveryInFlight`, and a Stop defers to it.
                assertionFailure("The recording ended while its capture restarted")
                awaitingRecoveryFrames = false
                Logger.state.error("The recording ended while its capture restarted — stopping the helper")
                // Never a capturing helper behind an idle app (L follow-up 29).
                _ = await boundedHelperStop("stop after an abandoned restart")
                return
            }
            // The old helper's alarms stay: the new helper's snapshot turns them stale, and only its
            // evidence on that track clears each one (§6.2).
            if awaitingRecoveryFrames { appState.interruptionWarning = "Recording restarted — waiting for audio…" }
        } catch {
            // FIRST, before any await: disarm crash detection (as the give-up branch does).
            captureClient.captureEnded()
            Logger.state.error("Restart failed: \(error, privacy: .private)")
            awaitingRecoveryFrames = false
            // Never a capturing helper behind an idle app (L9 review 44): a restart that captured, or whose
            // start timed out and may still commit, is stopped (bounded) before the salvage.
            let helperLetGo = await stopAfterFailedStart(captureStarted: captureStarted, startIssued: startIssued,
                                                         error: error, label: "stop after failed restart")
            guard helperLetGo else {
                // It may still be capturing — the restart's own capture, into THIS session — and hold the mic: HELD
                // (L review 81), salvage-only, never resumed. Nothing is transcribed now (L review 137): a transcript
                // written while the helper still writes would leave its later audio out. The chunks processed so far
                // are in session.json; the salvage, once the helper lets go, transcribes everything once.
                await settleAbandonedPipeline()
                appState.criticalError = "Recording failed — could not restart capture: \(error.localizedDescription). Its audio is kept; Parley will transcribe the recording once the capture helper lets go."
                appState.phase = .idle
                stopStatusPoll()
                keepMicMarked = true
                Logger.state.error("A failed restart left the capture helper unanswered — holding its session, untranscribed")
                holdForHelper(RecordingSentinel.read(directory: sentinelDirectory) ?? sentinel,
                              message: "Parley couldn’t stop the capture after the failed restart — its audio is kept, and Parley will transcribe it once the capture helper lets go.")
                notifyCritical("Recording Failed", appState.criticalError ?? "")
                return
            }
            // council F3: the orphan was already re-ingested above, so just finalize what's been processed
            // rather than abandoning the whole session. The restart's own file (the rotator's current chunk
            // now) holds audio only if the restart captured: sealed by the stop, it joins the salvage — never
            // while the helper may still be writing it.
            let restartFile = transcriptionRunner.chunkRotator.map { outputDir.appendingPathComponent($0.currentBaseName + ".wav").path }
            var reingest = false
            if helperLetGo, let restartFile {   // off the main actor, bounded (L review 122)
                reingest = await readOffMain("crash restart: restart file", folder: outputDir) { FileManager.default.fileExists(atPath: restartFile) } ?? false
            }
            let outcome = await finalizeAbandonedSession(at: Self.location(of: sentinel), reingestOrphan: reingest)
            appState.criticalError = "Recording failed — could not restart capture: \(error.localizedDescription). " + RecoveryMessages.outcomeSentence(outcome)
            appState.phase = .idle
            stopStatusPoll()
            finishSentinel(after: outcome, sentinel: sentinel)
            notifyCritical("Recording Failed", RecoveryMessages.recordingFailed(after: outcome))
        }
    }

    // MARK: - Launch recovery (§8.3, §8.9)

    /// A recording was running when the app last quit or crashed (the sentinel survived). The pure
    /// `RelaunchDecision` picks: re-attach to a helper that still captures (Flow A); resume the SAME
    /// session when the app was alive under 180 s ago; otherwise salvage what reached disk and say the
    /// recording STOPPED. A sentinel marked `stopping` is never resumed, one from another boot is stale,
    /// and an unreachable folder waits (the sentinel is never deleted before its salvage ran). Formerly
    /// `TranscriberApp.recoverIfNeeded`; here so every crash path is owned — and testable — in one place.
    public func recoverAtLaunch() async {
        if gateReservedForLaunch {
            gateReservedForLaunch = false   // held for this since the coordinator was made (L review 131)
        } else {
            // A retry that won the race to the gate finishes first.
            await awaitSettled { !$0.recoveryGateHeld }
            recoveryGateHeld = true
        }
        stoppedBatch = ([], [])
        if let sentinel = RecordingSentinel.read(directory: sentinelDirectory) {
            if await recover(sentinel) != .heldForHelper {
                // Sessions an earlier launch could not finish (their folder away, or the helper not letting go).
                await retryPendingLocked()
            } else {
                // The helper just refused to let go of THIS session: asking it again now would only wait out another
                // bound — but the OTHER pending sessions are not its capture, and are finished now (L review 118).
                await retryPendingLocked(helperHolds: sentinel.sessionKey)
            }
        } else {
            await retryPendingLocked()
        }
        releaseRecoveryGate()
    }

    /// The gate is free again: one row for the pass's `recordingStopped` messages, then a retry asked for
    /// meanwhile, if the app is idle.
    private func releaseRecoveryGate() {
        flushStoppedBatch()
        recoveryGateHeld = false
        if retryPendingWhenIdle, appState.isIdle, !isStartInFlight {
            Task { await self.retryPendingSessions() }
        }
    }

    /// A `recordingStopped` message: into the pass's one row when a recovery pass is running, else raised and
    /// presented at once. `recovered`: a salvage's (they are counted together).
    private func reportStopped(_ message: String, recovered: Bool) {
        if let batch = stoppedBatch {
            // Said once per pass, however many times the pass looks (L review 130).
            guard !batch.recovered.contains(message), !batch.other.contains(message) else { return }
            if recovered { stoppedBatch?.recovered.append(message) } else { stoppedBatch?.other.append(message) }
            return
        }
        appState.raiseAppAlarm(.recordingStopped, message: message)
        presentAlarms()
    }

    /// One row for everything a recovery pass has to say (L review 90): "N earlier recordings were recovered: …".
    private func flushStoppedBatch() {
        guard let batch = stoppedBatch else { return }
        stoppedBatch = nil
        var parts: [String] = []
        if batch.recovered.count == 1 {
            parts.append(batch.recovered[0])
        } else if batch.recovered.count > 1 {
            parts.append("\(batch.recovered.count) earlier recordings were recovered: " + batch.recovered.joined(separator: " "))
        }
        parts += batch.other
        guard !parts.isEmpty else { return }
        appState.raiseAppAlarm(.recordingStopped, message: parts.joined(separator: " "))
        presentAlarms()
    }

    private enum RelaunchOutcome { case handled, heldForHelper }

    /// After every await of a relaunch step (L follow-up 38, L reviews 112, 129): a Start that got in meanwhile owns
    /// the app, so the session waits for the next idle — pending, retried then — and nothing here touches that start
    /// (not its phase, not its crash detection). False when it yielded.
    private func yieldsToAStart(_ sentinel: RecordingSentinel) -> Bool {
        guard !appState.isIdle || userStartInFlight else { return true }
        Logger.state.info("A recording start is in flight — the relaunch session waits")
        keepPending(sentinel)
        retryPendingWhenIdle = true
        return false
    }

    private func recover(_ sentinel: RecordingSentinel) async -> RelaunchOutcome {
        Logger.state.info("Sentinel found — checking recovery (session: \(sentinel.sessionName, privacy: .sensitive), segment: \(sentinel.segment))")
        // Until the helper's state is settled, Record is disabled (L review 112).
        relaunchProbing = true
        if !startRunning { crashDuringStart = false }
        defer {
            relaunchProbing = false
            if !appState.isRecording, !startRunning { crashDuringStart = false }   // moot: nothing re-attached
        }
        let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        // Off the main actor, bounded (L review 75): a folder that does not answer is unreachable here — the
        // session waits, never salvaged as "no recorded audio".
        let probe = folderProbe
        let folderStatus = await readOffMain("relaunch: recording folder", folder: outputDir) { Self.folderStatus(outputDir, probe: probe) } ?? .unreachable

        // The callbacks are wired and crash detection armed BEFORE the ping (no start() in this process,
        // C1): a crash reported during it is heard (L round 5). Every path below that ends without a
        // capture disarms it again (`captureEnded`).
        wireCaptureCallbacks()
        captureClient.captureReattached()
        let helperState = await captureClient.captureState()
        // A Start pressed during the ping owns the app now (L follow-up 38): this session waits for the
        // next idle, and nothing here touches that start (not even its crash detection).
        guard yieldsToAStart(sentinel) else { return .handled }
        // A helper that did not answer may still be capturing (L9 review 49): never re-attached to, and
        // stopped — bounded — before any salvage or resume. One that will not stop keeps the session.
        if helperState == .unknown {
            let letGo = await boundedHelperStop("stop an unanswering helper at relaunch")
            guard yieldsToAStart(sentinel) else { return .handled }   // L review 112: after every await
            if !letGo {
                holdForHelper(sentinel)
                return .heldForHelper
            }
        }
        let helperCapturing = helperState == .capturing
        let decision = RelaunchDecision.decide(
            lastAliveAt: sentinel.lastAliveAt, bootSessionUUID: sentinel.bootSessionUUID, wasStopping: sentinel.stopping,
            now: Date(), helperCapturing: helperCapturing, currentBootSessionUUID: BootSession.currentUUID(),
            folderReachable: folderStatus == .reachable)
        Logger.state.info("Relaunch decision: \(String(describing: decision), privacy: .public)")

        switch decision {
        case .reattach:
            Logger.state.info("XPC service alive — re-attaching (Flow A)")
            // The session's folder, read off the main actor BEFORE the recording is re-attached (L review 75).
            let scan = await readOffMain("re-attach: session folder", folder: outputDir) { Self.scanForReattach(sentinel: sentinel, outputDir: outputDir) }
            // A Start pressed during the read owns the app now (as after the ping).
            guard yieldsToAStart(sentinel) else { return .handled }
            // From here to the adopt, all synchronous (L review 72): a crash or a Stop can only arrive once the
            // chunk pipeline exists — the crash path then names its restart from the live rotator, and a Stop
            // finishes the recording once, on the live pipeline (the orphans are already queued in it).
            appState.phase = .recording(since: sentinel.startedAt)
            setHelperMic(sentinel.micDeviceUID)   // keep level meters off it (#192)
            // Bound NOW (L review 121): what the pipeline's setup records — a re-attach that cannot rotate — is this
            // session's, and the adopt below, finding it bound, only drains.
            captureClient.bindSession(sessionId: stripSegmentSuffix(sentinel.systemAudioPath), directory: outputDir)
            reattachPipeline(sentinel: sentinel, outputDir: outputDir, scan: scan)
            // At once: the crashed app's last refresh may be minutes old, and a crash in the next minute
            // must still resume. The alive timer (with the status poll) takes over from here.
            refreshSentinelLiveness()
            startStatusPoll()
            // The evidence is this session's before anything is recorded into it (L follow-up 43).
            await captureClient.adoptSession(sessionId: stripSegmentSuffix(sentinel.systemAudioPath), directory: outputDir)
            // Re-checked after the await (L review 72): a Stop in the window owns the session now.
            guard appState.isRecording, !stopInFlight else {
                Logger.state.info("The re-attached recording was stopped while its session was adopted — nothing more to do")
                return .handled
            }
            captureClient.recordLaunchRecovery(["flow": "A", "reattach": "true"])
            // A crash in the window is being recovered: that recovery owns the helper now.
            guard !recoveryInFlight else { return .handled }
            // A crash reported before the phase was `.recording` — during the probe or the folder read (L review
            // 124) — was queued: recovered now, on the pipeline just built.
            if crashDuringStart {
                crashDuringStart = false
                Logger.state.warning("The helper crashed while the recording was being re-attached — crash recovery now")
                Task {
                    guard self.appState.isRecording else { return }
                    await self.handleXPCCrash()
                }
                return .handled
            }
            // Restore the helper's alarm state now: the pull on connect ran before anything listened.
            Task { await pollHelperStatus() }
        case .resumeSameSession(let lastAlive):
            return await resumeSameSession(sentinel: sentinel, outputDir: outputDir, lastAlive: lastAlive)
        case .salvageAndStop(let reason):
            // A stop-in-flight race: the helper may still be capturing (C7 round 1 — the decision only says
            // "never resume"; stopping the helper is ours), bounded, BEFORE the salvage, so the salvage sees
            // the chunk it seals. Unconditional (L review 84): only the helper's stop answer — "No capture in
            // progress" counts — releases the session, never a ping. A helper that will not stop keeps its
            // session: a file still being written is never salvaged (L follow-up 40).
            if reason == .wasStopping {
                let letGo = await boundedHelperStop("stop after relaunch")
                // A Start that got in during the stop owns the app now (L review 112): the session waits.
                guard yieldsToAStart(sentinel) else { return .handled }
                if !letGo {
                    holdForHelper(sentinel)
                    return .heldForHelper
                }
            }
            await salvageAtLaunch(sentinel: sentinel, outputDir: outputDir)
        case .salvageStale:
            await salvageAtLaunch(sentinel: sentinel, outputDir: outputDir)
        case .waitForFolder:
            // A stopping session's helper may still be capturing: stopped first, bounded, as a salvage does (L review
            // 128) — never `captureEnded` while it may still write. One that will not stop is held.
            if sentinel.stopping {
                let letGo = await boundedHelperStop("stop before waiting for the folder")
                guard yieldsToAStart(sentinel) else { return .handled }
                if !letGo {
                    holdForHelper(sentinel)
                    return .heldForHelper
                }
            }
            // Never deleted: the recording data may be on the missing drive (§8.9). No capture: disarmed.
            captureClient.captureEnded()
            keepPending(sentinel)
            await updateFolderAlarm()
        }
        return .handled
    }

    /// The session a relaunch continues: `session.json`'s, or — a crash inside the first chunk left none — a
    /// fresh one that began at the sentinel's start (L review 73: shared by the re-attach and the resume).
    private func seedState(for sentinel: RecordingSentinel, persisted: SessionState?) -> SessionState {
        let config = configManager.config
        return persisted ?? SessionState(sessionId: stripSegmentSuffix(sentinel.systemAudioPath), meetingStart: sentinel.startedAt,
                                         engine: config.engine.rawValue, chunkDurationMinutes: config.validatedChunkDuration)
    }

    /// Every chunk the crash cut short goes through the LIVE processor: its index lock is per instance
    /// (`ChunkedSessionRecovery` builds its own). A duplicate index is a no-op (R2). Shared by the re-attach and
    /// the resume (L review 73).
    private func ingestOrphans(_ orphans: [(chunk: CrashRecoveryPlanner.OrphanChunk, created: Date?)], outputDir: URL,
                               fallbackStart: Date) {
        guard let processor = transcriptionRunner.chunkProcessor else { return }
        for (orphan, created) in orphans {
            processor.processChunk(ChunkRotator.FinalizedChunk(
                index: orphan.index, systemPath: outputDir.appendingPathComponent(orphan.baseName + ".wav").path,
                micPath: outputDir.appendingPathComponent(orphan.baseName + "_mic.wav").path,
                startTime: created ?? fallbackStart))
        }
    }

    /// Flow A (L follow-up 30): the helper kept capturing, so the recording goes on — with its chunk
    /// pipeline rebuilt, seeded from `session.json`, and the rotator naming the helper's live file, so
    /// rotation, the disk checks and their alarms continue as normal. The live chunk rotates when IT is due
    /// (L review 77). A chunk the crash cut short (sealed, never processed) goes through the live processor;
    /// the live file is left to its rotation. Synchronous: called before the re-attach's first await.
    private func reattachPipeline(sentinel: RecordingSentinel, outputDir: URL, scan: ReattachScan?) {
        guard let scan else {
            reattachedWithoutPipeline(because: "its folder did not answer")
            return
        }
        let seed = seedState(for: sentinel, persisted: scan.persisted)
        do {
            try transcriptionRunner.setupChunkedPipeline(
                captureClient: captureClient, outputDirectory: outputDir, sessionBaseName: stripSegmentSuffix(sentinel.systemAudioPath),
                config: configManager.config, seededState: seed, firstChunkIndex: scan.liveIndex)
        } catch {
            reattachedWithoutPipeline(because: error.localizedDescription)
            return
        }
        guard let rotator = transcriptionRunner.chunkRotator else { return }
        if let began = scan.liveStartedAt { rotator.adoptCurrentChunk(startedAt: began) }
        rotator.start(firstRotationAt: rotator.currentChunkDue)
        wirePipelineHooks()
        ingestOrphans(scan.orphans, outputDir: outputDir, fallbackStart: seed.meetingStart)
        Logger.state.info("Re-attached at chunk \(scan.liveIndex, privacy: .public) with its pipeline")
    }

    /// The re-attached recording goes on without a chunk pipeline: nothing rotates, and it is transcribed from
    /// disk when it stops (the stop's fallback branch). Said, never only logged (L review 76).
    private func reattachedWithoutPipeline(because reason: String) {
        Logger.state.error("Re-attached without a chunk pipeline: \(reason, privacy: .private)")
        captureClient.record(.rotationFailed, .anomaly, ["error": "re-attached recording can't rotate", "reason": reason])
        if appState.raiseAppAlarm(.rotationFailed, message: "The re-attached recording can’t rotate its chunks — it keeps recording into one file, and is transcribed when you stop it.") {
            presentAlarms()
        }
    }

    /// The pending sessions. An unreadable list is set aside and said, never dropped (L review 89).
    private func pendingSessions() -> [RecordingSentinel] {
        let loaded = RecordingSentinel.loadPending(directory: sentinelDirectory)
        if let aside = loaded.setAside {
            reportStopped("Parley could not read its list of unfinished recordings — it was set aside in \(abbreviatedDisplayPath(aside.deletingLastPathComponent().path)), and those recordings may need to be transcribed by hand.",
                          recovered: false)
        } else if let kept = loaded.keptUnreadable {
            // Not "set aside": it could not even be moved. Left in place, never overwritten (L review 130).
            reportStopped("Parley could not read its list of unfinished recordings, nor move it aside — it is left in \(abbreviatedDisplayPath(kept.deletingLastPathComponent().path)), and those recordings may need to be transcribed by hand.",
                          recovered: false)
        }
        return loaded.sessions
    }

    /// Move a session the relaunch cannot finish now into the pending list — persisted, so a later
    /// recording's sentinel can never take its place (L follow-up 24) — and free the sentinel slot if it
    /// holds this session. Tracked ONCE, by session (L review 82): the newest copy — the slot's, when a resume
    /// rewrote it — replaces any earlier one in the list, and leaves the slot. `markStopping`: salvage-only.
    private func keepPending(_ sentinel: RecordingSentinel, markStopping: Bool = false) {
        let slot = RecordingSentinel.read(directory: sentinelDirectory)
        let slotIsThisSession = slot?.sessionKey == sentinel.sessionKey
        var kept = (slotIsThisSession ? slot : nil) ?? sentinel
        kept.stopping = kept.stopping || sentinel.stopping || markStopping
        kept.quitDuringFinalize = kept.quitDuringFinalize || sentinel.quitDuringFinalize
        var pending = pendingSessions().filter { $0.sessionKey != sentinel.sessionKey }
        pending.append(kept)
        do {
            try RecordingSentinel.writePending(pending, directory: sentinelDirectory)
        } catch {
            // Not written: the slot keeps it instead (marked), so the next launch still finds it.
            Logger.state.error("Could not keep the session for later: \(error, privacy: .private)")
            try? RecordingSentinel.write(kept, directory: sentinelDirectory)
            return
        }
        if slotIsThisSession {
            RecordingSentinel.delete(directory: sentinelDirectory)
        }
    }

    private func removePending(_ sentinel: RecordingSentinel) {
        let pending = pendingSessions().filter { $0.sessionKey != sentinel.sessionKey }
        do {
            try RecordingSentinel.writePending(pending, directory: sentinelDirectory)
        } catch {
            Logger.state.error("Could not update the pending sessions: \(error, privacy: .private)")
        }
    }

    /// The helper did not stop a recording (L follow-up 40; L review 81): its file may still be written, so it
    /// is not salvaged now. Held — marked `stopping` (salvage-only: never resumed) and pending (out of the slot a
    /// next Start writes), the helper's mic kept marked (#192, L review 88) — the user told (a sticky row), and
    /// finished at the next event once the helper's stop says it let go (L review 84).
    private func holdForHelper(_ sentinel: RecordingSentinel,
                               message: String = "Parley couldn’t stop the previous recording cleanly — its audio is kept, and Parley will finish it once the capture helper lets go.") {
        captureClient.captureEnded()
        setHelperMic(sentinel.micDeviceUID)
        keepPending(sentinel, markStopping: true)
        reportStopped(message, recovered: false)
    }

    /// `recordingFolderUnavailable` while any pending session's folder cannot be written, cleared otherwise.
    /// The folders are read off the main actor, bounded (L review 75); one that does not answer counts as
    /// unreachable.
    private func updateFolderAlarm() async {
        let pending = pendingSessions()
        applyFolderAlarm(pending: pending, folders: pending.isEmpty ? PendingFolders() : await pendingFolderStatuses(pending))
    }

    /// A session scan that timed out (L review 127): the session waits — pending, its folder counted as not
    /// answering, so the alarm says so until the next EVENT (a mount, a wake, a recording's end) reads it again,
    /// even if a read later in this pass answers. A Start that got in during the read owns the app: never its crash
    /// detection disarmed (L review 129).
    private func waitForUnansweringFolder(_ sentinel: RecordingSentinel) async {
        foldersNotAnswering.insert(sentinel.sessionKey)
        guard yieldsToAStart(sentinel) else { return }
        captureClient.captureEnded()
        keepPending(sentinel)
        await updateFolderAlarm()
    }

    private func applyFolderAlarm(pending: [RecordingSentinel], folders: PendingFolders) {
        foldersNotAnswering.formIntersection(pending.map(\.sessionKey))   // a session no longer pending is resolved
        // A folder with no answer YET — an earlier read of it is still out — says nothing either way (L review 164): the
        // alarm is left as it is, never raised as "not reachable" nor cleared on a guess.
        let folderOf = { (s: RecordingSentinel) in URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent().path }
        if pending.contains(where: { !foldersNotAnswering.contains($0.sessionKey) && folders.noAnswerYet.contains(folderOf($0)) }) {
            Logger.state.info("A pending folder has no answer yet — its alarm is left as it is")
            return
        }
        let waiting: [FolderStatus] = pending.map {
            foldersNotAnswering.contains($0.sessionKey) ? .unreachable : folders.statuses[folderOf($0)] ?? .unreachable
        }.filter { $0 != .reachable }
        if waiting.isEmpty {
            appState.clearAppAlarm(.recordingFolderUnavailable)
        } else if waiting.allSatisfy({ $0 == .notWritable }) {
            // There, but read-only: a permissions problem, not a missing drive (L review 79).
            appState.raiseAppAlarm(.recordingFolderUnavailable, message: "Parley can’t write to the recording folder — check its permissions. The recording data is kept, and Parley will retry.")
        } else {
            appState.raiseAppAlarm(.recordingFolderUnavailable, message: "The recording folder isn’t reachable — Parley will keep the recording data and retry.")
        }
    }

    /// Finish every pending session whose folder is back and whose capture the helper has let go of
    /// (L follow-ups 24, 35, 40). Event-driven, never a timer: at launch, when a volume mounts, when the
    /// Mac wakes, and when a recording ends. Only while idle with no start in flight — the sentinel slot
    /// and the helper are a recording's own then; asked for while busy, it runs at the next idle.
    public func retryPendingSessions() async {
        guard !pendingSessions().isEmpty else {
            appState.clearAppAlarm(.recordingFolderUnavailable)
            return
        }
        guard appState.isIdle, !isStartInFlight, !recoveryGateHeld else {
            retryPendingWhenIdle = true
            return
        }
        recoveryGateHeld = true
        stoppedBatch = ([], [])
        foldersNotAnswering.removeAll()   // an event: every folder is read again (L review 127)
        await retryPendingLocked()
        releaseRecoveryGate()
    }

    /// The retry itself, under the recovery gate.
    /// `helperHolds`: the session whose capture the helper just refused to let go of at this launch — left held,
    /// and the helper not asked again; every other ready session is finished (L review 118).
    private func retryPendingLocked(helperHolds heldKey: String? = nil) async {
        retryPendingWhenIdle = false
        let pending = pendingSessions()
        guard !pending.isEmpty else {
            appState.clearAppAlarm(.recordingFolderUnavailable)
            return
        }
        // Off the main actor, bounded (L review 75): folders that do not answer are not ready.
        let folders = await pendingFolderStatuses(pending)
        let ready = pending.filter {
            $0.sessionKey != heldKey && folders.statuses[URL(fileURLWithPath: $0.systemAudioPath).deletingLastPathComponent().path] == .reachable
        }
        if !ready.isEmpty {
            // Re-checked after the read (L follow-up 38): a start pressed meanwhile owns the app.
            guard appState.isIdle, !userStartInFlight else {
                retryPendingWhenIdle = true
                return
            }
            if heldKey == nil {
                // While idle, a capture the helper still holds is a previous recording's that did not stop. Only the
                // helper's stop answer releases a session — "No capture in progress" counts — never a ping, which
                // can read a slow helper as not capturing (L review 84).
                guard await boundedHelperStop("stop a pending session") else {
                    applyFolderAlarm(pending: pendingSessions(), folders: folders)
                    return   // still not letting go: the next event tries again
                }
                guard appState.isIdle, !userStartInFlight else {
                    retryPendingWhenIdle = true
                    return
                }
                clearHelperMic()   // the helper let go of the mic a held session kept marked (L review 88)
            }
            // The helper's events — the capture it held, sealed — go to the pending session that knows its helper
            // session (the held one included), or to none; drained ONCE, before any salvage binds (L review 98).
            let sessions = (ready + pending.filter { $0.sessionKey == heldKey }).map {
                (sessionId: stripSegmentSuffix($0.systemAudioPath), directory: URL(fileURLWithPath: $0.systemAudioPath).deletingLastPathComponent())
            }
            _ = try? await withDeadline(seconds: Self.seconds(folderReadDeadline), label: "pending: attribute the helper's events") {
                await self.attributeHelperDrain(sessions)
            }
            for sentinel in ready {
                guard appState.isIdle, !userStartInFlight else {
                    retryPendingWhenIdle = true
                    break
                }
                await salvageAtLaunch(sentinel: sentinel, outputDir: URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent())
            }
        }
        applyFolderAlarm(pending: pendingSessions(), folders: folders)
    }

    /// The bound on a folder or disk read off the main actor (L review 74, 75): a hung network share or a
    /// dying drive is named as the folder — never the audio system — and never stalls the UI. Tests shorten it.
    var folderReadDeadline: Duration = .seconds(5)
    /// What the folder reads ask the file system. Tests inject a slow or fake one.
    var folderProbe: FolderProbe = .live
    /// Where every blocking recording-folder read runs: a serial queue per volume, never the cooperative pool (L
    /// reviews 123, 160). Tests inject one that hangs.
    var folderReads: FolderReads = .shared

    /// A read of `folder`, off the main actor and bounded (on awake time): nil when it did not answer — or when the
    /// folder still has an earlier read outstanding (L reviews 123, 160: `FolderReads`, its volume's queue, never the pool).
    private func readOffMain<T>(_ label: String, folder: URL, bound: Duration? = nil, _ read: @escaping @Sendable () -> T) async -> T? {
        await folderReads.read(label, folder: folder.path, seconds: Self.seconds(bound ?? folderReadDeadline), read)
    }

    /// What the pending sessions' folders answered, by folder path (L reviews 75, 164). A read that timed out is
    /// `.unreachable`; a folder whose earlier read has not answered yet is in `noAnswerYet` — neither reachable nor not.
    struct PendingFolders {
        var statuses: [String: FolderStatus] = [:]
        var noAnswerYet: Set<String> = []
    }

    /// The status of each pending session's folder: each read on its own, concurrently — every one on its volume's
    /// queue, so a hung share never keeps a healthy folder from answering (L review 160) — and bounded.
    private func pendingFolderStatuses(_ sessions: [RecordingSentinel]) async -> PendingFolders {
        let probe = folderProbe, reads = folderReads, seconds = Self.seconds(folderReadDeadline)
        let folders = Set(sessions.map { URL(fileURLWithPath: $0.systemAudioPath).deletingLastPathComponent() })
        return await withTaskGroup(of: (String, FolderReads.Outcome<FolderStatus>).self) { group in
            for folder in folders {
                group.addTask {
                    (folder.path, await reads.outcome("pending folder", folder: folder.path, seconds: seconds) { Self.folderStatus(folder, probe: probe) })
                }
            }
            var result = PendingFolders()
            for await (path, outcome) in group {
                switch outcome {
                case .answered(let status): result.statuses[path] = status
                case .timedOut: result.statuses[path] = .unreachable
                case .busy: result.noAnswerYet.insert(path)
                }
            }
            return result
        }
    }

    /// Resume the crashed recording as the SAME session (§8.3): a new capture at a free chunk index, the
    /// chunk pipeline seeded from `session.json`, the chunks the crash cut short re-ingested through the
    /// live processor, and the gap recorded — in the session, in the record, and as the
    /// `recordingResumedWithGap` alarm. If the capture cannot restart, the session is salvaged instead and
    /// the recording is said STOPPED.
    private func resumeSameSession(sentinel: RecordingSentinel, outputDir: URL, lastAlive: Date?) async -> RelaunchOutcome {
        let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)   // the R5 session-id gate refuses any other
        let config = configManager.config
        // Both BEFORE the start (ledger, L7): the helper then creates the plan's file, which must be neither
        // a name already on disk (its audio would be overwritten) nor mistaken for an orphan (ingested
        // mid-recording, its real finalization would be skipped as a duplicate — the rest lost). Read off the
        // main actor, bounded (L review 75): a folder that does not answer waits.
        guard let scan = await readOffMain("resume: session folder", folder: outputDir, { Self.scanForResume(sentinel: sentinel, outputDir: outputDir, lastAlive: lastAlive) }) else {
            await waitForUnansweringFolder(sentinel)
            return .handled
        }
        // A finalized session is finished (L review 93): never resumed into — the salvage cleans up its leftovers.
        if scan.finalized {
            Logger.state.info("The session to resume was already transcribed — never resumed")
            captureClient.captureEnded()
            await salvageAtLaunch(sentinel: sentinel, outputDir: outputDir)
            return .handled
        }
        let plan = scan.plan, gapStart = scan.crashedAt
        let seed = seedState(for: sentinel, persisted: scan.persisted)
        Logger.state.info("Resuming the crashed session at chunk \(plan.index, privacy: .public) (\(scan.orphans.count, privacy: .public) orphan chunks)")

        // A user Start already running owns the helper: never race it, never clear its flag (L follow-up 38).
        guard !startRunning else {
            keepPending(sentinel)
            return .handled
        }
        // A start in flight: the phase stays `.idle` until the capture is up, so the Record control is
        // disabled, a user Start is ignored, and a crash reported meanwhile is handled once it is up (L5).
        startRunning = true
        defer { startRunning = false }
        crashDuringStart = false
        // Wired (before the ping) and armed BEFORE the start, as every start site: first frames reported
        // during `start()` are the resume's, and "Resumed" waits for them (§8.4).
        wireCaptureCallbacks()
        awaitingRecoveryFrames = true
        recoveryFramesAt = nil
        restartLostAudio = true
        acceptFramesBeforeRecording = true
        setHelperMic(sentinel.micDeviceUID)   // before the helper opens it (#192)
        // The evidence is this session's before the start could reset it (L follow-up 43).
        await captureClient.adoptSession(sessionId: sessionId, directory: outputDir)
        var startIssued = false, captureStarted = false
        do {
            startIssued = true
            try await captureClient.start(
                outputDirectory: outputDir,
                baseName: plan.baseName,
                microphoneDeviceId: sentinel.micDeviceUID,
                systemAudioSource: config.systemAudioSource,
                options: CaptureOptions(config: config),
                sessionId: sessionId
            )
            captureStarted = true
            var newSentinel = plan.newSentinel
            newSentinel.lastAliveAt = Date()
            newSentinel.bootSessionUUID = BootSession.currentUUID()
            newSentinel.stopping = false
            try RecordingSentinel.write(newSentinel, directory: sentinelDirectory)
            // The rotator is anchored at the current time inside: the monotonic clock behind it cannot be
            // persisted, so a resume re-anchors at resume time, never at the seeded `meetingStart` (C10).
            // `firstChunkIndex` is the plan's: the rotator must name the file the helper is writing.
            try transcriptionRunner.setupChunkedPipeline(
                captureClient: captureClient, outputDirectory: outputDir, sessionBaseName: sessionId,
                config: config, seededState: seed, firstChunkIndex: plan.index
            )
        } catch {
            Logger.state.error("Resume after a crash failed: \(error, privacy: .private)")
            transcriptionRunner.teardownChunkedPipeline()
            resetRecoveryConfirmation()
            crashDuringStart = false
            // Never a capturing helper behind an idle app — a start that timed out may still commit (L9 review
            // 44); its sealed file joins the salvage below. A helper that will not stop keeps the session: a file
            // still being written is never salvaged (27, 40).
            if !(await stopAfterFailedStart(captureStarted: captureStarted, startIssued: startIssued, error: error,
                                            label: "stop after failed resume")) {
                holdForHelper(sentinel)
                return .heldForHelper
            }
            clearHelperMic()
            startRunning = false   // this resume's own start is over: its salvage must not yield to it
            await salvageAtLaunch(sentinel: sentinel, outputDir: outputDir)
            return .handled
        }
        transcriptionRunner.startChunkRotation()
        wirePipelineHooks()
        ingestOrphans(scan.orphans, outputDir: outputDir, fallbackStart: seed.meetingStart)
        let now = Date()
        captureClient.recordLaunchRecovery(["flow": "resume", "gap_seconds": "\(max(0, Int(now.timeIntervalSince(gapStart))))"])
        captureClient.record(.captureGap, .anomaly, ["start": gapStart.ISO8601Format(), "end": now.ISO8601Format(), "reason": "app relaunch"])
        // In the session too (persisted to session.json, stamped into the transcript): re-detect's
        // audio-derived bound reads an unrecorded gap longer than a chunk as implausible timing. Awaited
        // before the phase flips, so nothing can end the recording under it.
        await transcriptionRunner.recordCaptureGap(CaptureGap(start: gapStart, end: now, reason: "app relaunch"))

        appState.phase = .recording(since: sentinel.startedAt)
        acceptFramesBeforeRecording = false   // resolved: from here on the phase admits frames
        startStatusPoll()                     // + the alive timer
        // Raised AND presented now (window + one notification — the presenter's is the only one, as for
        // `recordingStopped`, L6 fix round 1). "Recording Resumed" still waits for the first mic frames.
        appState.raiseAppAlarm(.recordingResumedWithGap, message: RecoveryMessages.resumedAfterCrash(crashedAt: gapStart, resumedAt: now))
        presentAlarms()
        if awaitingRecoveryFrames { appState.interruptionWarning = "Recording restarted — waiting for audio…" }
        if crashDuringStart {
            crashDuringStart = false
            Logger.state.warning("The helper crashed while the recording was resuming — crash recovery now")
            Task {
                guard self.appState.isRecording else { return }
                await self.handleXPCCrash()
            }
        }
        return .handled
    }

    // MARK: - Sentinel liveness (§8.3, §8.8)

    /// Stamp the sentinel's `lastAliveAt`: the alive timer, every rotation, a re-attach. Never creates
    /// one — no sentinel, no recording to vouch for.
    func refreshSentinelLiveness(now: Date = Date()) {
        // While a crash recovery runs the helper is dead: nothing is being captured to vouch for (L
        // follow-up 37). A successful restart stamps it again.
        guard !recoveryInFlight else { return }
        guard var sentinel = RecordingSentinel.read(directory: sentinelDirectory) else { return }
        sentinel.lastAliveAt = now
        do {
            try RecordingSentinel.write(sentinel, directory: sentinelDirectory)
        } catch {
            Logger.state.error("Could not refresh the recovery file's liveness: \(error, privacy: .private)")
        }
    }

    /// Stop marks the sentinel BEFORE it asks the helper (§8.8): from here a crash is salvaged at relaunch,
    /// never resumed — the user stopped this recording.
    func markSentinelStopping() {
        guard var sentinel = RecordingSentinel.read(directory: sentinelDirectory), !sentinel.stopping else { return }
        sentinel.stopping = true
        do {
            try RecordingSentinel.write(sentinel, directory: sentinelDirectory)
        } catch {
            Logger.state.error("Could not mark the recovery file as stopping: \(error, privacy: .private)")
        }
    }

    // MARK: - Pipeline hooks: liveness, disk, rotation and session-write failures (§8.3, §8.7)

    /// The live pipeline's hooks. Every rotation refreshes the sentinel's liveness and checks the disk; a
    /// rotation failure and a `session.json` write failure become alarms and provenance events.
    private func wirePipelineHooks() {
        transcriptionRunner.chunkRotator?.onRotated = { [weak self] in
            self?.refreshSentinelLiveness()
            self?.rotationSucceeded()
        }
        transcriptionRunner.chunkRotator?.onRotationFailed = { [weak self] error in self?.rotationFailed(error) }
        // The rotator looks at the folder through the coordinator's reader, off the main actor (L review 158); a look
        // that did not answer is on record — the recording itself goes on.
        transcriptionRunner.chunkRotator?.folderReads = folderReads
        transcriptionRunner.chunkRotator?.onFolderNotAnswering = { [weak self] step in
            self?.captureClient.record(.folderNotAnswering, .anomaly, ["during": step])
        }
        transcriptionRunner.chunkProcessor?.onSessionWriteFailure = { [weak self] index in self?.sessionWriteFailed(chunk: index) }
        // The progress file is written again: its alarm is over (L follow-up 26, R2's hook).
        transcriptionRunner.chunkProcessor?.onSessionWriteSucceeded = { [weak self] in self?.appState.clearAppAlarm(.sessionWriteFailed) }
    }

    /// A rotation worked: rotation is not broken any more, and the disk is checked for the next chunk —
    /// `diskLow` below one chunk, cleared only above two (hysteresis, `DiskSpaceCheck.rotationVerdict`). The
    /// read runs off the main actor, bounded (L11 review 70): a hung network volume never stalls the UI, and a
    /// read that does not answer skips this rotation's check — logged, never guessed.
    private func rotationSucceeded() {
        guard appState.isRecording else { return }
        appState.clearAppAlarm(.rotationFailed)
        guard let dir = transcriptionRunner.chunkRotator?.sessionLocation.outputDir else { return }
        let provider = freeBytesProvider, bound = Self.seconds(rotationDiskReadDeadline), probe = folderProbe
        rotationDiskCheckGeneration += 1
        let generation = rotationDiskCheckGeneration
        let reads = folderReads
        rotationDiskCheck = Task { [weak self] in
            // On the folder queue, never the cooperative pool (L review 123).
            guard let answer = await reads.read("rotation disk read", folder: dir.path, seconds: bound, {
                provider(Self.nearestExistingDirectory(dir, probe: probe))
            }) else {
                Logger.state.error("The free-space read at a rotation did not answer within \(bound, privacy: .public) s — this rotation's disk check is skipped")
                return
            }
            guard let self, let free = answer, generation == self.rotationDiskCheckGeneration else { return }
            self.applyRotationDiskVerdict(free: free)
        }
    }

    /// Returns once the latest rotation's disk check has finished. Internal for tests.
    func awaitRotationDiskCheckForTesting() async {
        await rotationDiskCheck?.value
    }

    private func applyRotationDiskVerdict(free: Int) {
        guard appState.isRecording else { return }
        let verdict = DiskSpaceCheck.rotationVerdict(freeBytes: free, chunkMinutes: configManager.config.validatedChunkDuration,
                                                     currentlyLow: appState.activeAlarms[.diskLow] != nil)
        switch verdict {
        case .low:
            captureClient.record(.diskLow, .warning, ["free_mb": "\(free / 1_000_000)"])
            if appState.raiseAppAlarm(.diskLow, message: "Less than one chunk of free space — Parley keeps recording, but free some space now.") {
                presentAlarms()
            }
        case .ok:
            appState.clearAppAlarm(.diskLow)
        }
    }

    /// A helper reply the app acts on (§8.6, §8.7; H2's `CaptureReplies`).
    enum HelperReply: Equatable {
        /// "No capture in progress": nothing is capturing. On a rotate a dead capture (the crash path); on a
        /// stop, the helper has let go.
        case notCapturing
        /// "Refused: capture is starting or stopping": a stop is under way in the helper. A rotate is refused,
        /// not dead (council B-I3); a second stop is asked again shortly.
        case stopping
        /// "Rotation timed out": the writer swap overran and may land late — a refused rotation, reconciled like
        /// the client's own timeout (L review 91b).
        case rotationTimedOut
        /// "Capture already in progress": the helper still holds an earlier capture (a held session's).
        case alreadyCapturing
        /// The start was cancelled by a stop or a disconnect during it ("Capture cancelled — stopped while
        /// starting"), or — the stop's reply — the start it arrived during ended ("Capture start cancelled"):
        /// nothing is capturing.
        case startCancelled
        /// "Capture start timed out": the helper abandoned the start at its own deadline — the audio system.
        case startTimedOut
        /// Anything else (a timeout, a writer error, an XPC failure).
        case other
    }

    /// The one place that reads the helper's replies (L review 91, item 48): matched EXACTLY, by H2's
    /// `CaptureReplies` constants — the errors carry the helper's text as it is.
    nonisolated static func helperReply(_ reply: String) -> HelperReply {
        switch reply {
        case CaptureReplies.noCaptureInProgress: return .notCapturing
        case CaptureReplies.refusedStopping: return .stopping
        case CaptureReplies.rotationTimedOut: return .rotationTimedOut
        case CaptureReplies.alreadyInProgress: return .alreadyCapturing
        case CaptureReplies.cancelledWhileStarting, CaptureReplies.startCancelled: return .startCancelled
        case CaptureReplies.startTimedOut: return .startTimedOut
        default: return .other
        }
    }

    /// A rotation threw. The current chunk keeps recording under its index; the alarm says the file may
    /// not rotate again. "No capture in progress" is the helper answering that it is not capturing — a
    /// dead capture, so the crash path restarts it (§8.7).
    private func rotationFailed(_ error: Error) {
        // A rotate that races a Stop or a crash recovery is the recording ending or restarting: those
        // paths own the capture, and a rotation "failure" then is neither an anomaly nor an alarm.
        guard appState.isRecording, !stopInFlight, !recoveryInFlight else { return }
        let reason = error.localizedDescription
        let failure = Self.helperReply(reason)
        // The helper refused because it is stopping: the recording is ending, not dead (council B-I3).
        guard failure != .stopping else {
            Logger.state.info("A rotation was refused: the helper is stopping")
            return
        }
        captureClient.record(.rotationFailed, .anomaly, ["error": reason])
        if appState.raiseAppAlarm(.rotationFailed, message: "A chunk rotation failed — the current chunk keeps recording, but the file may not rotate again.") {
            presentAlarms()
        }
        guard failure == .notCapturing else { return }
        Logger.state.error("A rotation found the helper not capturing — crash recovery")
        Task {
            guard self.appState.isRecording else { return }
            await self.handleXPCCrash()
        }
    }

    /// R2's hook: `session.json` could not be written — after a chunk, or (nil) a session-level change such
    /// as a capture gap. The audio is intact, but an interruption now may not recover the last chunk.
    private func sessionWriteFailed(chunk index: Int?) {
        captureClient.record(.sessionWriteFailed, .anomaly, ["chunk": index.map { "\($0)" } ?? "session"])
        if appState.raiseAppAlarm(.sessionWriteFailed, message: "Parley could not save its progress file — if it is interrupted now, the last chunk may not be recovered.") {
            presentAlarms()
        }
    }

    /// A crashed recording that is not resumed: transcribe what reached disk, present it like a normal
    /// stop (completion notice + rename), and say loudly — the sticky `recordingStopped` alarm, presented
    /// at once (window + one notification) — that the recording STOPPED and what was written (§7.4 P6).
    /// The relaunch decision calls it, a resume that cannot restart the capture, and the pending retry. Wherever the
    /// session came from, it leaves BOTH the slot and the list once salvaged (L review 82).
    func salvageAtLaunch(sentinel: RecordingSentinel, outputDir: URL) async {
        let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)
        // When the recording stopped, what is on disk, and an older-format file's last write — read before the
        // salvage archives (deletes) its orphan WAVs, off the main actor and bounded (L review 75). A folder that
        // does not answer is not salvaged: the session waits.
        guard let scan = await readOffMain("salvage: session folder", folder: outputDir, { Self.scanForSalvage(sentinel: sentinel, outputDir: outputDir) }) else {
            await waitForUnansweringFolder(sentinel)
            return
        }
        // A Start during the read owns the app now (L review 129): never `.transcribing` over it, never its crash
        // detection disarmed — the session waits.
        guard yieldsToAStart(sentinel) else { return }
        if scan.finalized == .cleanedUp {
            // Already transcribed: the recovery file lingered — a crash between the transcript and the sentinel's
            // delete, or a held session transcribed before its hold (L review 136). Its leftovers were cleaned up
            // (R2's `cleanupFinalized`, L review 94) and that is all: no second finalize, no rename panel, no row.
            Logger.state.info("The recovery file of an already transcribed recording lingered — its leftovers are cleaned up, nothing is transcribed again")
            forgetSession(sentinel)
            captureClient.captureEnded()
            // Audio written AFTER the transcript, which it does not list, is never silent (L review 137): the scan
            // noted it in the record; the row says where it is kept.
            if scan.lateAudioSeconds > 0 {
                let minutes = max(1, Int((scan.lateAudioSeconds / 60).rounded()))
                reportStopped("Recording STOPPED — \(minutes) min of audio recorded after its transcript was written \(minutes == 1 ? "is" : "are") kept in \(abbreviatedDisplayPath(outputDir.path)), not transcribed.",
                              recovered: false)
            }
            return
        }
        let stoppedAt = scan.stoppedAt, chunkCount = scan.chunkCount
        appState.phase = .transcribing(progress: "Recovering…")
        let outcome: SalvageOutcome
        var recovered: TranscriptionResult?
        do {
            let config = configManager.config
            let (transcriber, diarizer) = try prepareEngines(config: config)
            // Bound to this session BEFORE its drain (L review 98): reset, drain, build — as the resume does. What
            // the helper still holds is this session's (a pending retry attributed a stray helper's already).
            await captureClient.adoptSession(sessionId: sessionId, directory: outputDir)
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
                // Chunks whose speech recognition failed are never called "transcribed" (R2 item 9, L review 93):
                // counted from the transcript just written, off the main actor.
                let jsonPath = result.jsonPath
                let failures = await readOffMain("salvage: transcript", folder: outputDir) { SalvageOutcome.recognitionFailures(inTranscriptAt: jsonPath) } ?? nil
                outcome = SalvageOutcome(kind: .transcriptWritten(result.jsonPath), chunkCount: chunkCount,
                                         recognitionFailures: failures ?? .init())
                captureClient.commitSessionDiagnostics(sessionId: sessionId, directory: outputDir)   // L review 97
            } else {
                Logger.state.info("Chunked session had nothing to recover")
                // Chunks on disk that produced nothing are kept, not "no recorded audio" (L round 5). A finalized
                // session whose transcript cannot be read back had nothing to rebuild it from: its audio is kept.
                let why = scan.finalized == .damaged
                    ? "its transcript could not be read back, and no progress file was left to rebuild it from"
                    : "none of their audio could be processed"
                outcome = chunkCount > 0
                    ? SalvageOutcome(kind: .finalizeFailed(why), chunkCount: chunkCount)
                    : SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0)
                // Nothing on disk at all: nothing to keep evidence for. Chunks kept untranscribed keep theirs.
                if chunkCount == 0 { captureClient.commitSessionDiagnostics(sessionId: sessionId, directory: outputDir) }
            }
        } catch {
            Logger.state.error("Chunked session recovery failed: \(error, privacy: .private)")
            outcome = SalvageOutcome(kind: .finalizeFailed(error.localizedDescription), chunkCount: chunkCount)
        }
        // Only now, the salvage having run: out of the pending list AND out of the slot (L review 82).
        forgetSession(sentinel)
        if let recovered {
            await presentCompletedTranscription(recovered)   // completion notice, rename + auto-summary
        }
        if case .transcribing = appState.phase { appState.phase = .idle }
        // Raised AND presented (window + one notification) — at once, or with the rest of its recovery pass as
        // ONE row (L review 90). The presenter's notification is the only one: no separate critical alert (L6 fix
        // round 1). An older-format (pre-0.6, single-file) recording is not a chunk: kept, and never "no recorded
        // audio" (L follow-up 25); STOPPED when its file was last written, never its start (L review 86). The
        // message names its folder, not the meeting.
        let message: String
        if sentinel.quitDuringFinalize {
            message = RecoveryMessages.quitWhileFinishing(outcome: outcome)   // a quit, not a crash (L follow-up 42)
        } else if outcome.kind == .nothingToSalvage, scan.legacyAudio {
            message = RecoveryMessages.relaunchStoppedKeepingOlderFormat(at: scan.legacyLastWrite.map { min($0, Date()) },
                                                                         folder: abbreviatedDisplayPath(outputDir.path))
        } else if Self.stoppedByRestart(sentinel) {
            message = RecoveryMessages.relaunchStoppedByRestart(at: stoppedAt, outcome: outcome)   // never "crashed" (L review 69)
        } else {
            message = RecoveryMessages.relaunchStopped(at: stoppedAt, outcome: outcome)
        }
        // Only a written transcript is a recovery (L review 133): nothing to salvage, or chunks kept untranscribed,
        // are said on their own — never counted in "N earlier recordings were recovered".
        if case .transcriptWritten = outcome.kind { reportStopped(message, recovered: true) } else { reportStopped(message, recovered: false) }
        captureClient.captureEnded()
    }

    /// The live pipeline of a session that is NOT finalized now (L review 137): the chunks already queued are
    /// processed — each persisted to session.json — then the rotation stops and the pipeline goes. A later salvage
    /// finishes the session from there.
    private func settleAbandonedPipeline() async {
        transcriptionRunner.stopChunkRotation()
        if let processor = transcriptionRunner.chunkProcessor { await processor.awaitAllProcessed() }
        transcriptionRunner.teardownChunkedPipeline()
    }

    /// A recording ended on a failure path: its recovery file goes — unless its folder did not answer, when nothing
    /// could be checked or salvaged: then it is KEPT, salvage-only, and finished when the folder answers (L review
    /// 122).
    private func finishSentinel(after outcome: SalvageOutcome, sentinel: RecordingSentinel?) {
        guard outcome.kind == .folderNotAnswering else {
            RecordingSentinel.delete(directory: sentinelDirectory)
            return
        }
        if let kept = RecordingSentinel.read(directory: sentinelDirectory) ?? sentinel { keepPending(kept, markStopping: true) }
    }

    /// The capture died and its restart could not be planned: the recording folder did not answer (L review 122).
    /// The recording ends — said so — and its recovery file is kept, salvage-only, for when the folder answers.
    private func endRecordingFolderNotAnswering(_ sentinel: RecordingSentinel) async {
        captureClient.captureEnded()
        awaitingRecoveryFrames = false
        transcriptionRunner.stopChunkRotation()
        transcriptionRunner.teardownChunkedPipeline()
        keepPending(sentinel, markStopping: true)
        let message = "Recording failed — the capture stopped, and the recording folder isn’t answering, so it could not be restarted. Its audio is kept; Parley will finish it when the folder answers."
        appState.criticalError = message
        appState.phase = .idle
        stopStatusPoll()
        notifyCritical("Recording Failed", message)
        await updateFolderAlarm()
    }

    /// The session is out of the pending list AND out of the slot (L review 82) — the slot only when it holds
    /// this session, never another recording's sentinel.
    private func forgetSession(_ sentinel: RecordingSentinel) {
        removePending(sentinel)
        if RecordingSentinel.read(directory: sentinelDirectory)?.sessionKey == sentinel.sessionKey {
            RecordingSentinel.delete(directory: sentinelDirectory)
        }
    }

    /// The Mac restarted (or lost power) while this session was recording (R2 follow-up 1, L review 69): its
    /// sentinel is from another boot and was not stopping — the relaunch decision's `salvageStale`, and a
    /// session a launch like that kept pending.
    nonisolated static func stoppedByRestart(_ sentinel: RecordingSentinel, currentBoot: String? = BootSession.currentUUID()) -> Bool {
        guard !sentinel.stopping, let recorded = sentinel.bootSessionUUID, let currentBoot else { return false }
        return recorded != currentBoot
    }

    private static func location(of sentinel: RecordingSentinel) -> (outputDir: URL, sessionId: String) {
        (URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent(), stripSegmentSuffix(sentinel.systemAudioPath))
    }

    /// Nothing transcribed (no live pipeline, or a salvage that produced nothing): say what is on disk.
    /// "Nothing to salvage" would be false when chunks are there — they are kept, just not transcribed
    /// (§7.4 P6).
    /// The count is read off the main actor, bounded (L review 122): a folder that does not answer is said so.
    private func unsalvagedOutcome(at location: (outputDir: URL, sessionId: String)?, why: String) async -> SalvageOutcome {
        guard let location else { return SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0) }
        guard let count = await readOffMain("salvage: chunks on disk", folder: location.outputDir, {
            Self.chunksOnDisk(outputDir: location.outputDir, sessionId: location.sessionId, finalized: false)
        }) else { return SalvageOutcome(kind: .folderNotAnswering, chunkCount: 0) }
        return count > 0
            ? SalvageOutcome(kind: .finalizeFailed(why), chunkCount: count)
            : SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0)
    }

    /// Where the session's audio is: the sentinel's (it survives a relaunch) or, without one, the
    /// stopped capture's. Nil when neither is known.
    private static func sessionLocation(sentinel: RecordingSentinel?, stoppedPaths: AudioPaths?) -> (outputDir: URL, sessionId: String)? {
        guard sentinel != nil || stoppedPaths != nil else { return nil }
        return fallbackSessionLocation(sentinel: sentinel, stoppedSystemAudioPath: stoppedPaths?.systemAudio.path ?? "")
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
        at location: (outputDir: URL, sessionId: String),
        reingestOrphan: Bool
    ) async -> SalvageOutcome {
        guard let processor = transcriptionRunner.chunkProcessor else {
            transcriptionRunner.teardownChunkedPipeline()
            return await unsalvagedOutcome(at: location, why: "transcription was not running in this session")
        }
        let outputDir = location.outputDir
        transcriptionRunner.stopChunkRotation()

        var orphan: (index: Int, baseName: String)?
        if reingestOrphan, let rotator = transcriptionRunner.chunkRotator {
            orphan = await reingestOrphanChunk(rotator: rotator, processor: processor, outputDir: outputDir)
        }

        await processor.awaitAllProcessed()
        let sessionState = await processor.getSessionState()
        let outcome = await salvageAbandonedSession(sessionState: sessionState, outputDir: outputDir)
        switch outcome.kind {
        case .nothingToSalvage:
            // Nothing transcribed, yet audio may be on disk (a chunk that could not be processed):
            // report it as kept, not as "no recorded audio" (L6 fix round 1).
            return await unsalvagedOutcome(at: location, why: "its audio could not be processed")
        case .transcriptWritten:
            // The in-progress chunk was re-ingested but did not make it into the transcript: say its
            // audio is on disk, untranscribed — checked off the main actor, bounded (L review 122); unanswered, not claimed.
            if let orphan, !sessionState.chunks.contains(where: { $0.index == orphan.index }) {
                let wav = outputDir.appendingPathComponent(orphan.baseName + ".wav").path
                if await readOffMain("salvage: last chunk", folder: outputDir, { FileManager.default.fileExists(atPath: wav) }) == true {
                    return SalvageOutcome(kind: outcome.kind, chunkCount: outcome.chunkCount, lastChunkKeptOnDisk: true,
                                          recognitionFailures: outcome.recognitionFailures)
                }
            }
            return outcome
        case .finalizeFailed, .folderNotAnswering:
            return outcome
        }
    }

    /// The salvage decision + execution half of `finalizeAbandonedSession`, split out verbatim
    /// behind an internal seam: the `!chunks.isEmpty` guard, provenance stamping, and the
    /// teardown-on-empty path are unit-testable with a crafted `SessionState` — the wrapper above
    /// requires a live `chunkProcessor`, which tests don't have.
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
            captureClient.commitSessionDiagnostics(sessionId: sessionState.sessionId, directory: outputDir)   // L review 97
        } catch {
            // Reported, not swallowed (§7.4 P6): the chunks stay on disk, untranscribed.
            Logger.state.error("Salvage finalize failed: \(error, privacy: .private)")
            kind = .finalizeFailed(error.localizedDescription)
        }
        transcriptionRunner.teardownChunkedPipeline()
        // Chunks whose recognition failed are never called "transcribed" (R2 item 9, L review 93).
        return SalvageOutcome(kind: kind, chunkCount: sessionState.chunks.count,
                              recognitionFailures: SalvageOutcome.recognitionFailures(in: sessionState.chunks))
    }

    // MARK: - Shared steps (deduplicated from MenuView)

    /// The post-transcription success sequence, previously duplicated verbatim in both the chunked
    /// and fallback branches of `stopRecording`: publish the transcript paths, return to idle,
    /// notify, then hand off to the rename dialog + auto-summary. Internal for tests.
    func presentCompletedTranscription(_ result: TranscriptionResult) async {
        appState.lastJsonPath = result.jsonPath.path
        appState.lastTranscriptPath = result.jsonPath.path
        // Say so when the capture layer flagged something. This used to be an unconditional
        // "Transcription Complete" while `capture_provenance` sat right here recording that the
        // recording was compromised — the app knew and the user did not (#58).
        // Off the main actor: this is a synchronous file read of a transcript that can reach several
        // hundred KB for a long meeting, on a path that has just finished writing it. `RecordingCoordinator`
        // is @MainActor, so doing it inline would block the UI at exactly the wrong moment.
        // The notice names every problem the transcript itself records (§7.3, council C-C2): capture
        // anomalies, chunks with processing problems, and an empty transcript. A plain "Transcription
        // Complete" only when it is truly clean.
        let jsonPath = result.jsonPath
        // On the folder queue, bounded (L review 122, 123): unanswered reads as "couldn't re-read the transcript".
        let unreadable = CaptureQualityNotice.unreadable
        let (anomalies, problemChunks, segments) = await readOffMain("completion: transcript", folder: jsonPath.deletingLastPathComponent()) {
            (CaptureQualityNotice.anomalyCount(inTranscriptAt: jsonPath),
             CaptureQualityNotice.problemChunkCount(inTranscriptAt: jsonPath),
             CaptureQualityNotice.segmentCount(inTranscriptAt: jsonPath))
        } ?? (unreadable, unreadable, unreadable)
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
            CaptureQualityNotice.completionTitle(anomalyCount: anomalies, problemChunkCount: problemChunks, segmentCount: segments),
            CaptureQualityNotice.completionBody(
                fileName: result.jsonPath.lastPathComponent, anomalyCount: anomalies,
                problemChunkCount: problemChunks, segmentCount: segments)
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
    ) async -> (index: Int, baseName: String) {
        // A timed-out rotation the helper completed late: the orphan is the chunk it was really writing, and
        // the chunk it sealed goes through the pipeline from its own files (L9 review 46). Not a rotation (118).
        // The folder is looked at off the main actor, bounded (L review 158).
        await rotator.reconcileLateRotation(announce: false)
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

/// A recording-folder read did not answer within its bound (L review 122).
struct FolderNotAnswering: Error, LocalizedError {
    var errorDescription: String? { "the recording folder isn’t answering" }
}

/// Whether the repair path has answered, shared by the capped wait and the answer (main actor).
@MainActor
private final class RepairAnswer {
    var arrived = false
}
