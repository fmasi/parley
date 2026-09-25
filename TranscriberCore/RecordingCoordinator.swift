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
    /// The capture's mic frames came back after the implicit wake: a real didWake then records no second gap — that
    /// audio was captured (L review 162).
    var framesSinceImplicitWake = false
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
    /// An exit's flush of the live logs ran out of its bound (L review 195): the folder is not answering, and the app's own
    /// last flush (`applicationWillTerminate`) is skipped — it would only hold the exit past its bound again.
    public internal(set) var exitFlushTimedOut = false
    /// The bound on the live-log flush of the Quit and the termination preparation (L review 96), never past their own
    /// deadline (L review 145). Tests shorten it.
    var evidenceFlushBound: Duration = .seconds(1)
    /// How long `willPowerOff`'s quit mark on a transcript being finished stands (L review 174): a logout or shutdown ends
    /// the app well within it, and one the user cancelled leaves the app running past it — the mark then goes, so a later
    /// crash is said as a crash. As `TerminationPolicy.powerOffWindow`. Tests shorten it.
    var powerOffMarkWindow: Duration = .seconds(TerminationPolicy.powerOffWindow)
    /// The pending expiry of `willPowerOff`'s quit mark.
    var powerOffMarkExpiry: Task<Void, Never>?
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
    /// outside a pass. Each with the session it is about (nil: none — a note about the pending list, say).
    private var stoppedBatch: (recovered: [(session: String?, message: String)], other: [(session: String?, message: String)])?
    /// The sessions a pass already said are waiting for the transcription engine (L review 178): said once per run, never
    /// again at every wake or mount while the engine is still not ready.
    private var saidWaitingForEngine: Set<String> = []
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
    /// The relaunch probing the helper — its wait for the recovery gate, its ping, and the stops it may need — counts too
    /// (L reviews 112, 159, 161): Record is disabled until the helper's state is settled, and no longer — a salvage that
    /// follows is not a start. So does a pending retry's own helper stop (L review 161).
    public var isStartInFlight: Bool { startAnnounced || startRunning || relaunchProbing || pendingHelperStopInFlight }
    /// A start that is not the relaunch's own: what every relaunch step yields to after an await (L reviews 38,
    /// 112, 129).
    var userStartInFlight: Bool { startAnnounced || startRunning }
    private var relaunchProbing = false
    /// The relaunch's ping answered `.capturing` (Flow A): a capture is running while the relaunch settles it (L review
    /// 170). Meaningful only while `relaunchProbing`.
    private var probeFoundCapture = false
    /// A Quit now would leave a running capture behind (L review 170): the relaunch found one and has not settled it yet —
    /// not re-attached (then it is a recording), not stopped.
    var relaunchFoundCapture: Bool { relaunchProbing && probeFoundCapture }
    /// A pending retry is asking the helper to let go (L review 161).
    private var pendingHelperStopInFlight = false
    private var startAnnounced = false
    private var startRunning = false
    /// A start refused because the helper is busy with an earlier capture: the pending retry runs once it is over.
    private var retryAfterStart = false
    /// The helper crashed (or failed fatally) before the recording was up: while a start awaited it, while the relaunch
    /// probed a capture it may re-attach to (L review 124), or while a resume started it (L review 182: named for all
    /// three). The phase was still `.idle`, and the client reports a crash once per capture generation, so dropping it
    /// would leave a dead recording. Handled as soon as the recording is up; moot if it never is.
    private(set) var crashBeforeRecording = false

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
            crashBeforeRecording = false
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
        crashBeforeRecording = false
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
            if crashBeforeRecording {
                crashBeforeRecording = false
                Logger.state.warning("The helper crashed while the recording was starting — crash recovery now")
                Task {
                    guard self.appState.isRecording else { return }
                    await self.handleXPCCrash()
                }
            }
        } catch {
            crashBeforeRecording = false   // moot: this failure path ends the recording
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
            if reply == .alreadyCapturing {
                // What the refused start drained is the busy capture's: to the pending session that knows it (L review 157).
                await captureClient.attributeRefusedStartDrain(toOneOf: pendingSessions().map {
                    (sessionId: stripSegmentSuffix($0.systemAudioPath), directory: URL(fileURLWithPath: $0.systemAudioPath).deletingLastPathComponent())
                })
            }
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
                    holdForHelper(held, message: "Parley couldn’t stop the capture of the recording that failed to start — its audio is kept, and Parley will finish it once the capture helper lets go.",
                                  cause: .startFailed, reason: .startFailed)
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
        // Its looks included (L review 208): a rotation that has not sent its rotate never will, now the rotator is stopped.
        let rotationBound = transcriptionRunner.chunkRotator?.rotationBoundSeconds ?? ChunkRotator.rotateCallSeconds
        _ = try? await withDeadline(seconds: rotationBound, label: "rotation before stop") { await self.awaitRotationInFlight() }
        var stoppedPaths: AudioPaths?
        do {
            // Bounded (§8.8): a helper that never answers is salvaged from disk in the catch below. A stop already under
            // way in the helper is waited for, within the same deadline (L review 148).
            let paths = try await userStop()
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

                // Final merge. The record is written off the main actor, bounded (L review 185): the menu says "Finishing…"
                // meanwhile, and stays responsive.
                appState.phase = .transcribing(progress: "Finishing…")
                var sessionState = await processor.getSessionState()
                let outputDir = paths.systemAudio.deletingLastPathComponent()
                // Drain capture diagnostics, flush <session>.diag.jsonl only if anomalous, and stamp
                // the always-present provenance into the transcript metadata (#95).
                sessionState.provenance = await captureClient.finalizeSessionDiagnostics(
                    sessionId: sessionState.sessionId,
                    engine: configManager.config.engine.rawValue,
                    recordingDirectory: outputDir,
                    drainHelper: true
                )
                useFolderReadsForTheTranscript()
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
                guard let look = await readOffMain("stop: session folder", folder: sessionOutputDir, {
                    (recoverable: CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory: sessionOutputDir, sessionId: sessionId),
                     toRecognise: Self.chunkCounts(outputDir: sessionOutputDir, sessionId: sessionId, finalized: false).onDisk)
                }) else { throw FolderNotAnswering() }
                if look.recoverable {
                    let config = configManager.config
                    // The engine first, as a launch salvage checks it (L reviews 178, 218): one that cannot be made — or whose
                    // speech model is not there while there is audio to recognise — keeps the session pending, never "could not
                    // be transcribed" and forgotten.
                    let transcriber: any TranscriptionEngine, diarizer: (any DiarizationProvider)?
                    do {
                        (transcriber, diarizer) = try prepareEngines(config: config)
                        if look.toRecognise > 0 {
                            let engine = transcriber
                            guard await Task.detached(operation: { engine.isReady() }).value else { throw EngineNotReady() }
                        }
                    } catch {
                        throw EngineUnavailable(why: error.localizedDescription)
                    }
                    // Drain capture diagnostics and stamp the always-present provenance into the
                    // recovered transcript's metadata, same as a clean stop does (#154 finding 1) —
                    // otherwise a recovered session's `sessionState.provenance` stays nil forever.
                    let provenance = await captureClient.finalizeSessionDiagnostics(
                        sessionId: sessionId,
                        engine: config.engine.rawValue,
                        recordingDirectory: sessionOutputDir,
                        drainHelper: true
                    )
                    result = try await recoverChunkedSession(outputDirectory: sessionOutputDir, sessionId: sessionId, config: config,
                                                             transcriber: transcriber, diarizer: diarizer, provenance: provenance)
                    // Only a transcript commits the evidence (L reviews 97, 140): nil is audio kept untranscribed — its
                    // live log stays beside it.
                    if result != nil { captureClient.commitSessionDiagnostics(sessionId: sessionId, directory: sessionOutputDir) }
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
                        recordingDirectory: outputDir,
                        drainHelper: true
                    )

                    useFolderReadsForTheTranscript()
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
            // The helper refused because ANOTHER stop is still under way in it, past the Stop's deadline (L review 148):
            // its files may still be written. Not "the helper is gone": the mic stays marked, nothing is re-ingested or
            // salvaged now — the session is held, and finished once the helper lets go.
            if !stopSucceeded, Self.helperReply(error.localizedDescription) == .stopping {
                Logger.state.error("The Stop found another stop still under way in the capture helper — holding the session")
                // Where the session is, BEFORE the pipeline goes with its rotator (L review 188): with no recovery file left,
                // the session is held from there — with the mic still marked — so it is always pending, and the mic is released
                // once the helper lets go.
                let location = Self.sessionLocation(sentinel: sentinel, stoppedPaths: nil) ?? transcriptionRunner.chunkRotator?.sessionLocation
                let marked = recordingMicrophone.current
                await settleAbandonedPipeline()
                let message = "Stopping the recording is taking longer than expected — another stop is still under way in the capture helper. Its audio is kept, and Parley will finish it once the capture helper lets go."
                // The user's own Stop (L review 186): never "its capture failed".
                if let held = RecordingSentinel.read(directory: sentinelDirectory) ?? sentinel
                    ?? location.map({ Self.keptSentinel(for: $0, cause: .stopInterrupted, micDeviceUID: marked ?? nil) }) {
                    if sentinel == nil { Logger.state.error("The held Stop's session has no recovery file — held from where its pipeline was") }
                    holdForHelper(held, message: message, cause: .stopInterrupted, reason: .stopUnderWay)
                } else {
                    Logger.state.error("The held Stop's session has no recovery file and no known folder")
                    reportStopped("Stopping the recording is taking longer than expected — another stop is still under way in the capture helper, and Parley has no record of where the recording is. Check the recordings folder.", recovered: false)
                }
                appState.errorMessage = message
                appState.phase = .idle
                return
            }
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
            // The transcription engine was not ready for the rebuild (L review 218, as 178): the session waits for it —
            // pending, said, and finished after Setup, a model download or a Settings save.
            if let waiting = error as? EngineUnavailable {
                transcriptionRunner.teardownChunkedPipeline()
                keepForTheEngine(sentinel: sentinel, location: location, why: waiting.why)
                appState.phase = .idle
                return
            }
            let outcome: SalvageOutcome
            if error is FolderNotAnswering {
                // BEFORE any other salvage choice (L review 211): nothing could be checked or written — the session is kept for
                // when the folder answers. Never a second look under another key that answers and forgets it.
                transcriptionRunner.stopChunkRotation()
                transcriptionRunner.teardownChunkedPipeline()
                outcome = SalvageOutcome(kind: .folderNotAnswering, chunkCount: 0)
            } else if transcriptionRunner.chunkProcessor != nil, let location {
                outcome = await finalizeAbandonedSession(at: location, reingestOrphan: !stopSucceeded)
            } else {
                transcriptionRunner.teardownChunkedPipeline()
                // The helper's replies in words, never its wire text (L review 189).
                outcome = await unsalvagedOutcome(at: location, why: Self.describe(error))
            }
            finishSentinel(after: outcome, sentinel: sentinel, location: location)
            // The helper's replies in words, never its wire text (L review 148).
            let why = Self.describe(error)
            appState.errorMessage = why
            // #155: this catch is the stop path's only signal to the user. It says what the salvage did and what is on
            // disk (§7.4 P6), and whether the stop itself failed or only the transcript. The recovery file goes with the
            // salvage — unless the folder did not answer: then it is kept, salvage-only, for when it does (L review 122).
            let body = stopSucceeded
                ? RecoveryMessages.transcriptionFailed(after: outcome, error: why)
                : RecoveryMessages.stopFailed(after: outcome, error: why)
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
            if startRunning || relaunchProbing { crashBeforeRecording = true }
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
        if implicitWakeAt != nil { framesSinceImplicitWake = true }
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
    private func attributeHelperDrain(_ sessions: [(sessionId: String, directory: URL)]) async -> Bool {
        await captureClient.attributeHelperDrain(toOneOf: sessions)
    }
    private func flushEvidence() async { await captureClient.flushEvidence() }

    /// Every queued live-log write reaches the disk before the process ends (L review 96) — bounded: a stuck disk
    /// never holds an exit longer than `evidenceFlushBound`, nor past the exit's own `deadline` (L review 145). Whatever
    /// is left unflushed is flushed again, bounded, when the app terminates (`LiveDiagnosticsLog.flushAll(within:)`).
    func flushEvidenceForExit(by deadline: SuspendingClock.Instant? = nil) async {
        let bound = deadline.map { min(evidenceFlushBound, max(.zero, $0 - .now)) } ?? evidenceFlushBound
        let finished = (try? await withDeadline(seconds: max(0.001, Self.seconds(bound)), label: "exit: evidence flush") {
            await self.flushEvidence()
            return true
        }) ?? false
        // Ran out: a folder is not answering — the app's own last flush is skipped, never a second wait past the exit's bound
        // (L review 195).
        if !finished {
            Logger.state.error("The exit's flush of the live logs ran out of its bound — a recording folder is not answering")
            exitFlushTimedOut = true
        }
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
    /// The least of the Stop's deadline a re-ask must have left (L review 187). Tests shorten it.
    var stopReaskMinimumBudget: Duration = .seconds(1)

    /// The user's Stop asks the helper, bounded by `stopDeadline` (§8.8). "Refused: capture is starting or stopping" —
    /// another stop already under way in the helper — is waited for: asked again, within the same deadline (L review
    /// 148). Throws the last refusal when it outlasts the deadline.
    ///
    /// Held, never timing-dependent (L review 187): a re-ask needs `stopReaskMinimumBudget` of the deadline left — with less,
    /// the session is held without asking again — and a re-ask that times out after a refusal was seen is that other stop
    /// still under way: its refusal is thrown (held), never a timeout that drops the connection and re-ingests a chunk the
    /// other stop may still be writing.
    private func userStop() async throws -> AudioPaths {
        let deadline = SuspendingClock.now + stopDeadline
        var refusal: Error?
        while true {
            do {
                return try await bounded("stop", seconds: Self.seconds(until: deadline)) { try await self.helperStop() }
            } catch let timeout as CaptureCallTimeout {
                guard let refusal else { throw timeout }
                Logger.state.error("A re-asked stop did not answer after the helper refused it — another stop is still under way; held")
                throw refusal
            } catch where Self.helperReply(error.localizedDescription) == .stopping {
                refusal = error
                guard SuspendingClock.now + stopReaskInterval + stopReaskMinimumBudget <= deadline else {
                    Logger.state.error("Another stop is still under way in the capture helper, too close to the Stop's deadline to ask again — held")
                    throw error
                }
                Logger.state.info("Another stop is under way in the capture helper — the Stop waits for it")
                try? await Task.sleep(for: stopReaskInterval)
            }
        }
    }

    /// A helper call's failure in the user's words: the helper's replies are named for what they mean, never shown as
    /// their wire text (L review 148). Any other error keeps its own description.
    nonisolated static func describe(_ error: Error) -> String {
        switch helperReply(error.localizedDescription) {
        case .notCapturing: return "the capture had already stopped"
        case .stopping: return "another stop was still under way in the capture helper"
        case .rotationTimedOut: return "the capture helper did not finish a chunk in time"
        case .alreadyCapturing: return "the capture helper was still busy with an earlier recording"
        case .startCancelled: return "the start was cancelled"
        case .startTimedOut: return "the audio system didn’t respond"
        case .other: return error.localizedDescription
        }
    }

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
                // "Parley will finish it when the folder answers" — so it is kept (L review 163).
                finishSentinel(after: outcome, sentinel: nil, location: location)
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
                appState.criticalError = "Recording failed — could not restart capture: \(Self.describe(error)). Its audio is kept; Parley will transcribe the recording once the capture helper lets go."
                appState.phase = .idle
                stopStatusPoll()
                keepMicMarked = true
                Logger.state.error("A failed restart left the capture helper unanswered — holding its session, untranscribed")
                holdForHelper(RecordingSentinel.read(directory: sentinelDirectory) ?? sentinel,
                              message: "Parley couldn’t stop the capture after the failed restart — its audio is kept, and Parley will transcribe it once the capture helper lets go.",
                              cause: .captureFailed, reason: .restartFailed)
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
                guard let exists = await readOffMain("crash restart: restart file", folder: outputDir, { FileManager.default.fileExists(atPath: restartFile) }) else {
                    // Unanswered: the restart's file may hold audio — never dropped by a transcript written without it. The
                    // chunks so far are settled; the session is kept for when the folder answers (L review 163).
                    await settleAbandonedPipeline()
                    endRecordingFolderNotAnswering(sentinel, reason: "could not restart capture: \(Self.describe(error))")
                    await updateFolderAlarm()
                    return
                }
                reingest = exists
            }
            let outcome = await finalizeAbandonedSession(at: Self.location(of: sentinel), reingestOrphan: reingest)
            // The helper's replies in words, never its wire text (L review 189).
            appState.criticalError = "Recording failed — could not restart capture: \(Self.describe(error)). " + RecoveryMessages.outcomeSentence(outcome)
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
        // Busy from here, the gate's wait included (L review 161): Record stays disabled until the helper is settled.
        relaunchProbing = true
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
            relaunchProbing = false   // nothing to probe
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
    /// presented at once. `recovered`: a salvage's (they are counted together). `session`: the session it is about (its
    /// key), nil for a note about no one session.
    private func reportStopped(_ message: String, recovered: Bool, session: String? = nil) {
        if let batch = stoppedBatch {
            // Said once per pass, however many times the pass looks (L review 130) — deduplicated by SESSION, never by the
            // text alone: two sessions whose rows read the same are both said (L review 180).
            let entry = (session: session, message: message)
            guard !(batch.recovered + batch.other).contains(where: { $0.session == entry.session && $0.message == entry.message }) else { return }
            if recovered { stoppedBatch?.recovered.append(entry) } else { stoppedBatch?.other.append(entry) }
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
            parts.append(batch.recovered[0].message)
        } else if batch.recovered.count > 1 {
            parts.append("\(batch.recovered.count) earlier recordings were recovered: " + batch.recovered.map(\.message).joined(separator: " "))
        }
        parts += batch.other.map(\.message)
        guard !parts.isEmpty else { return }
        appState.raiseAppAlarm(.recordingStopped, message: parts.joined(separator: " "))
        presentAlarms()
    }

    private enum RelaunchOutcome { case handled, heldForHelper }

    /// After every await of a relaunch step (L follow-up 38, L reviews 112, 129, 161): a Start that got in meanwhile — the
    /// user's, announced or running — owns the app, so the session waits for the next idle — pending, retried then — and
    /// nothing here touches that start (not its phase, not its crash detection). Checked BEFORE anything disarms or arms
    /// crash detection. False when it yielded.
    private func stillOwnsTheSession(_ sentinel: RecordingSentinel) -> Bool {
        guard !appState.isIdle || userStartInFlight else { return true }
        Logger.state.info("A recording start is in flight — the relaunch session waits")
        keepPending(sentinel)
        retryPendingWhenIdle = true
        return false
    }

    private func recover(_ sentinel: RecordingSentinel) async -> RelaunchOutcome {
        Logger.state.info("Sentinel found — checking recovery (session: \(sentinel.sessionName, privacy: .sensitive), segment: \(sentinel.segment))")
        // Until the helper's state is settled, Record is disabled (L review 112) — and no longer (L review 159): each
        // decision below clears it once the helper has let go, or is capturing the re-attached recording.
        relaunchProbing = true
        probeFoundCapture = false
        if !startRunning { crashBeforeRecording = false }
        defer {
            relaunchProbing = false
            probeFoundCapture = false
            if !appState.isRecording, !startRunning { crashBeforeRecording = false }   // moot: nothing re-attached
        }
        let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        // Off the main actor, bounded (L review 75): a folder that does not answer is unreachable here — the
        // session waits, never salvaged as "no recorded audio".
        let probe = folderProbe
        let folderStatus = await readOffMain("relaunch: recording folder", folder: outputDir) { Self.folderStatus(outputDir, probe: probe) } ?? .unreachable
        // A Start pressed during the read owns the app: checked BEFORE anything is armed or pinged (L review 161).
        guard stillOwnsTheSession(sentinel) else { return .handled }

        // The callbacks are wired and crash detection armed BEFORE the ping (no start() in this process,
        // C1): a crash reported during it is heard (L round 5). Every path below that ends without a
        // capture disarms it again (`captureEnded`).
        wireCaptureCallbacks()
        captureClient.captureReattached()
        let helperState = await captureClient.captureState()
        // A Start pressed during the ping owns the app now (L follow-up 38): this session waits for the
        // next idle, and nothing here touches that start (not even its crash detection).
        guard stillOwnsTheSession(sentinel) else { return .handled }
        // A capture is running from here until it is re-attached or stopped: a Quit meanwhile is a Quit of a recording (L
        // review 170) — asked, and the recording stopped within its bound — never an exit that leaves it running.
        probeFoundCapture = helperState == .capturing
        // A helper that did not answer may still be capturing (L9 review 49): never re-attached to, and
        // stopped — bounded — before any salvage or resume. One that will not stop keeps the session.
        if helperState == .unknown {
            let letGo = await boundedHelperStop("stop an unanswering helper at relaunch")
            guard stillOwnsTheSession(sentinel) else { return .handled }   // L review 112: after every await
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
            guard stillOwnsTheSession(sentinel) else { return .handled }
            if scan?.finalized == true {
                // Already transcribed — a held restart's helper went on writing it: never re-attached, which would
                // finalize it a second time over its transcript (L review 157). The capture is stopped (bounded); the
                // salvage then cleans up and says what was recorded after the transcript (L review 137).
                Logger.state.info("The capturing session was already transcribed — stopping its capture, never re-attached")
                let letGo = await boundedHelperStop("stop the capture of a finished session")
                guard stillOwnsTheSession(sentinel) else { return .handled }
                if !letGo {
                    holdForHelper(sentinel)
                    return .heldForHelper
                }
                relaunchProbing = false
                await salvageAtLaunch(sentinel: sentinel, outputDir: outputDir)
                return .handled
            }
            // From here to the adopt, all synchronous (L review 72): a crash or a Stop can only arrive once the
            // chunk pipeline exists — the crash path then names its restart from the live rotator, and a Stop
            // finishes the recording once, on the live pipeline (the orphans are already queued in it).
            appState.phase = .recording(since: sentinel.startedAt)
            relaunchProbing = false   // the recording is re-attached: the phase says it from here (L review 159)
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
            await captureClient.adoptSession(sessionId: stripSegmentSuffix(sentinel.systemAudioPath), directory: outputDir, drainHelper: true)
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
            if crashBeforeRecording {
                crashBeforeRecording = false
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
            relaunchProbing = false   // the helper is not capturing: the resume's own start is in flight from its start
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
                guard stillOwnsTheSession(sentinel) else { return .handled }
                if !letGo {
                    holdForHelper(sentinel)
                    return .heldForHelper
                }
            }
            relaunchProbing = false   // the helper let go: a salvage is no start (L review 159)
            await salvageAtLaunch(sentinel: sentinel, outputDir: outputDir)
        case .salvageStale:
            relaunchProbing = false
            await salvageAtLaunch(sentinel: sentinel, outputDir: outputDir)
        case .waitForFolder:
            // A stopping session's helper may still be capturing: stopped first, bounded, as a salvage does (L review
            // 128) — never `captureEnded` while it may still write. One that will not stop is held.
            if sentinel.stopping {
                let letGo = await boundedHelperStop("stop before waiting for the folder")
                guard stillOwnsTheSession(sentinel) else { return .handled }
                if !letGo {
                    holdForHelper(sentinel)
                    return .heldForHelper
                }
            }
            // Never deleted: the recording data may be on the missing drive (§8.9). No capture: disarmed.
            relaunchProbing = false
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
            // Not "set aside": it could not even be moved. Left in place, never overwritten (L review 130); the recordings
            // Parley keeps since go to a new list beside it, so every hold is tracked (L review 166).
            reportStopped("Parley could not read its list of unfinished recordings, nor move it aside — it is left in \(abbreviatedDisplayPath(kept.deletingLastPathComponent().path)), and those recordings may need to be transcribed by hand. Recordings Parley keeps since go to a separate list beside it.",
                          recovered: false)
        }
        // A list kept beside it that cannot be read is said too — never only a log line (L review 196).
        for list in loaded.unreadableOverflow {
            reportStopped("Parley could not read a list of unfinished recordings (\(list.lastPathComponent)) — it is left as it is in \(abbreviatedDisplayPath(list.deletingLastPathComponent().path)), and those recordings may need to be transcribed by hand.",
                          recovered: false)
        }
        return loaded.sessions
    }

    /// Move a session the relaunch cannot finish now into the pending list — persisted, so a later
    /// recording's sentinel can never take its place (L follow-up 24) — and free the sentinel slot if it
    /// holds this session. Tracked ONCE, by session (L review 82): the newest copy — the slot's, when a resume
    /// rewrote it — replaces any earlier one in the list, and leaves the slot. `markStopping`: salvage-only.
    /// `cause`: why it stopped, as this launch — or this session — sees it; stamped once, the first keeping's standing
    /// (L review 147). Without one, this launch's: the Mac restarted, or Parley went. `held`: why the helper holds it —
    /// stamped once too (L review 177).
    private func keepPending(_ sentinel: RecordingSentinel, markStopping: Bool = false, cause: RecordingSentinel.StopCause? = nil,
                             held: RecordingSentinel.HeldReason? = nil) {
        let slot = RecordingSentinel.read(directory: sentinelDirectory)
        let slotIsThisSession = slot?.sessionKey == sentinel.sessionKey
        var kept = (slotIsThisSession ? slot : nil) ?? sentinel
        kept.stopCause = kept.stopCause ?? sentinel.stopCause ?? cause ?? Self.relaunchCause(sentinel)
        kept.heldReason = kept.heldReason ?? sentinel.heldReason ?? held
        kept.stopping = kept.stopping || sentinel.stopping || markStopping
        kept.salvageBegan = kept.salvageBegan || sentinel.salvageBegan
        // A quit's own mark wins over `willPowerOff`'s time-boxed one (L review 174).
        let quit = kept.quitDuringFinalize || sentinel.quitDuringFinalize
        let onlyPowerOff = (!kept.quitDuringFinalize || kept.quitMarkedByPowerOff) && (!sentinel.quitDuringFinalize || sentinel.quitMarkedByPowerOff)
        kept.quitDuringFinalize = quit
        kept.quitMarkedByPowerOff = quit && onlyPowerOff
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
    /// finished at the next event once the helper's stop says it let go (L review 84). `reason`: why it is held, carried on
    /// the pending entry (L review 177) — the relaunch's by default.
    private func holdForHelper(_ sentinel: RecordingSentinel,
                               message: String = "Parley couldn’t stop the previous recording cleanly — its audio is kept, and Parley will finish it once the capture helper lets go.",
                               cause: RecordingSentinel.StopCause? = nil, reason: RecordingSentinel.HeldReason = .relaunch) {
        captureClient.captureEnded()
        setHelperMic(sentinel.micDeviceUID)
        keepPending(sentinel, markStopping: true, cause: cause, held: reason)
        reportStopped(message, recovered: false, session: sentinel.sessionKey)
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
        guard stillOwnsTheSession(sentinel) else { return }
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

    /// The transcription engine may be ready now — a model download finished, Setup completed, the engine was changed (L
    /// review 178): the sessions kept waiting for it are retried. Nothing pending: nothing to do.
    public func transcriptionEngineMayBeReady() async {
        await retryPendingSessions()
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
        // While a held helper has not let go, no HELD session is salvaged (L review 183): the stuck helper's capture may be
        // any of theirs — an older held session's chunk still being written. They wait for the helper's stop; a session
        // never held (its folder was away, say) is not the helper's, and is finished now.
        let helperHoldsOn = heldKey != nil
        let ready = pending.filter {
            $0.sessionKey != heldKey && !(helperHoldsOn && $0.heldReason != nil)
                && folders.statuses[URL(fileURLWithPath: $0.systemAudioPath).deletingLastPathComponent().path] == .reachable
        }
        if helperHoldsOn, pending.contains(where: { $0.sessionKey != heldKey && $0.heldReason != nil }) {
            Logger.state.info("A held capture helper has not let go — the other held sessions wait for its stop")
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
                // Busy while it asks (L review 161): Record is disabled, an exit waits for the answer.
                pendingHelperStopInFlight = true
                let letGo = await boundedHelperStop("stop a pending session")
                pendingHelperStopInFlight = false
                guard letGo else {
                    applyFolderAlarm(pending: pendingSessions(), folders: folders)
                    return   // still not letting go: the next event tries again
                }
                guard appState.isIdle, !userStartInFlight else {
                    retryPendingWhenIdle = true
                    return
                }
                clearHelperMic()   // the helper let go of the mic a held session kept marked (L review 88)
            }
            if heldKey == nil {
                // The helper's events — the capture it held, sealed — go to the pending session that knows its helper
                // sessions, or to none; drained ONCE, before any salvage binds (L review 98). A drain that did not answer
                // leaves them in the helper: no salvage binds and drains them now, as its own — they wait for the next
                // event (L review 142).
                let sessions = ready.map {
                    (sessionId: stripSegmentSuffix($0.systemAudioPath), directory: URL(fileURLWithPath: $0.systemAudioPath).deletingLastPathComponent())
                }
                let answered = (try? await withDeadline(seconds: Self.attributionBound, label: "pending: attribute the helper's events") {
                    await self.attributeHelperDrain(sessions)
                }) ?? false
                guard answered else {
                    Logger.state.error("The capture helper's events could not be drained — the pending recordings wait for the next event")
                    // Said, never silent while they wait (L review 201).
                    reportStopped(RecoveryMessages.waitingForHelperDrain(count: ready.count), recovered: false)
                    applyFolderAlarm(pending: pendingSessions(), folders: folders)
                    return
                }
                guard appState.isIdle, !userStartInFlight else {
                    retryPendingWhenIdle = true
                    return
                }
            }
            for sentinel in ready {
                guard appState.isIdle, !userStartInFlight else {
                    retryPendingWhenIdle = true
                    break
                }
                // While the helper still holds a held session's capture, its events are that session's: never drained
                // into another salvage (L review 167).
                await salvageAtLaunch(sentinel: sentinel, outputDir: URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent(),
                                      drainHelper: heldKey == nil)
            }
        }
        applyFolderAlarm(pending: pendingSessions(), folders: folders)
    }

    /// The outer bound on a pending pass's attribution of the helper's events (L review 205): the drain's own 3 s, the
    /// evidence's bounded folder reads (`SessionEvidence.folderDeadlineSeconds`, read concurrently), and a second's margin —
    /// so the outer bound never fires while the attribution is still within its own.
    nonisolated static let attributionBound: Double = 3 + SessionEvidence.folderDeadlineSeconds + 1

    /// The bound on a folder or disk read off the main actor (L review 74, 75): a hung network share or a
    /// dying drive is named as the folder — never the audio system — and never stalls the UI. Tests shorten it.
    var folderReadDeadline: Duration = .seconds(5)
    /// The bound on the transcript's writes (L review 185): longer than a read — a slow share writes a long meeting's
    /// record — never unbounded. Tests shorten it.
    var folderWriteDeadline: Duration = .seconds(30)
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
        // A Start that got in during the scan owns the app — announced or running — before anything here disarms or
        // starts: never raced, never its flag cleared, never its crash detection disarmed (L follow-up 38, L review 161).
        guard stillOwnsTheSession(sentinel) else { return .handled }
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
        // A start in flight: the phase stays `.idle` until the capture is up, so the Record control is
        // disabled, a user Start is ignored, and a crash reported meanwhile is handled once it is up (L5).
        startRunning = true
        defer { startRunning = false }
        crashBeforeRecording = false
        // Wired (before the ping) and armed BEFORE the start, as every start site: first frames reported
        // during `start()` are the resume's, and "Resumed" waits for them (§8.4).
        wireCaptureCallbacks()
        awaitingRecoveryFrames = true
        recoveryFramesAt = nil
        restartLostAudio = true
        acceptFramesBeforeRecording = true
        setHelperMic(sentinel.micDeviceUID)   // before the helper opens it (#192)
        // The evidence is this session's before the start could reset it (L follow-up 43).
        await captureClient.adoptSession(sessionId: sessionId, directory: outputDir, drainHelper: true)
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
            // A live recording again (L review 192): no stale cause, quit mark or hold carries into it.
            newSentinel.stopping = false
            newSentinel.stopCause = nil
            newSentinel.quitDuringFinalize = false
            newSentinel.quitMarkedByPowerOff = false
            newSentinel.heldReason = nil
            newSentinel.salvageBegan = false
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
            crashBeforeRecording = false
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
        if crashBeforeRecording {
            crashBeforeRecording = false
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
        // Late chunks the Stop could not check (L review 213): on record, and said — never dropped silently.
        transcriptionRunner.chunkRotator?.onLateChunksUnchecked = { [weak self] indices in self?.lateChunksUnchecked(indices) }
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

    /// The Stop could not check whether late chunks the helper may have recorded are on disk (L review 213): recorded, and
    /// said in a row naming their files — kept there if they are, not transcribed.
    private func lateChunksUnchecked(_ indices: [Int]) {
        captureClient.record(.folderNotAnswering, .anomaly, ["during": "stop", "unchecked_chunks": indices.map(String.init).joined(separator: ",")])
        guard let location = transcriptionRunner.chunkRotator?.sessionLocation else { return }
        let files = indices.map { "\(location.sessionId)-\($0).wav" }
        reportStopped(RecoveryMessages.lateChunksUnchecked(files: files, folder: abbreviatedDisplayPath(location.outputDir.path)),
                      recovered: false)
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
    /// `drainHelper` false: the helper still holds a held session's capture — this salvage binds without draining it (L
    /// review 167).
    func salvageAtLaunch(sentinel: RecordingSentinel, outputDir: URL, drainHelper: Bool = true) async {
        let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)
        // Before the first await: a Quit from here on came while Parley was RECOVERING it (L review 194).
        markSalvageBegan(sentinel)
        // When the recording stopped, what is on disk, and an older-format file's last write — read before the
        // salvage archives (deletes) its orphan WAVs, off the main actor and bounded (L review 75). A folder that
        // does not answer is not salvaged: the session waits.
        guard let scan = await readOffMain("salvage: session folder", folder: outputDir, { Self.scanForSalvage(sentinel: sentinel, outputDir: outputDir) }) else {
            await waitForUnansweringFolder(sentinel)
            return
        }
        // A Start during the read owns the app now (L review 129): never `.transcribing` over it, never its crash
        // detection disarmed — the session waits.
        guard stillOwnsTheSession(sentinel) else { return }
        if scan.finalized == .cleanedUp {
            // Already transcribed: the recovery file lingered — a crash between the transcript and the sentinel's
            // delete, or a held session transcribed before its hold (L review 136). Its leftovers were cleaned up
            // (R2's `cleanupFinalized`, L review 94) and that is all: no second finalize, no rename panel, no row.
            Logger.state.info("The recovery file of an already transcribed recording lingered — its leftovers are cleaned up, nothing is transcribed again")
            // Its transcript verified: the commit a crash cut short happens now — its live log and coverage go (L review
            // 144) — but only once its record is BUILT (L review 200): the crashed process may never have written it, and
            // the live log may be its only copy. Built without draining: the helper's events are not this session's to take.
            // A record that cannot be written keeps the live log (the commit's unwritten guard).
            await captureClient.adoptSession(sessionId: sessionId, directory: outputDir, drainHelper: false)
            _ = await captureClient.finalizeSessionDiagnostics(sessionId: sessionId, engine: configManager.config.engine.rawValue,
                                                               recordingDirectory: outputDir, drainHelper: false)
            captureClient.commitSessionDiagnostics(sessionId: sessionId, directory: outputDir)
            forgetSession(sentinel)
            captureClient.captureEnded()
            // Kept because its folder stopped answering — its transcript's write landed once it answered (L review 185):
            // the user was told it would be finished, so it is said that it was, never silence.
            if sentinel.stopCause == .folderNotAnswering {
                reportStopped(RecoveryMessages.finishedOnceTheFolderAnswered(transcript: "\(sessionId).json"), recovered: true,
                              session: sentinel.sessionKey)
            }
            // Audio written AFTER the transcript, which it does not list, is never silent (L review 137): the scan
            // noted it in the record; the row says how much, beside which transcript, and where it is kept (L review 181).
            if let late = scan.lateAudio {
                reportStopped(RecoveryMessages.audioAfterTranscript(seconds: late.seconds, transcript: late.transcript,
                                                                    folder: abbreviatedDisplayPath(outputDir.path)),
                              recovered: false, session: sentinel.sessionKey)
            }
            return
        }
        let stoppedAt = scan.stoppedAt, chunkCount = scan.chunkCount
        let config = configManager.config
        // The engine, before anything is bound, drained or written (L review 178). One that is not there — it cannot be
        // made on this macOS, or its speech model is not downloaded while there is audio to recognise — is not the audio's
        // failure: the session stays pending, said so, and is finished once the engine is ready. A session whose every
        // chunk is already transcribed needs no engine.
        let transcriber: any TranscriptionEngine, diarizer: (any DiarizationProvider)?
        do {
            (transcriber, diarizer) = try prepareEngines(config: config)
            if scan.orphanCount > 0 {
                let engine = transcriber
                guard await Task.detached(operation: { engine.isReady() }).value else { throw EngineNotReady() }
            }
        } catch {
            Logger.state.error("The transcription engine is not ready — the session waits for it: \(error, privacy: .private)")
            // A Start during the engine check owns the app now: the session waits all the same, and nothing touches that start.
            guard stillOwnsTheSession(sentinel) else { return }
            keepPending(sentinel)
            if saidWaitingForEngine.insert(sentinel.sessionKey).inserted {
                reportStopped(RecoveryMessages.waitingForEngine(at: stoppedAt, folder: abbreviatedDisplayPath(outputDir.path),
                                                                why: error.localizedDescription),
                              recovered: false, session: sentinel.sessionKey)
            }
            captureClient.captureEnded()
            return
        }
        guard stillOwnsTheSession(sentinel) else { return }
        saidWaitingForEngine.remove(sentinel.sessionKey)
        appState.phase = .transcribing(progress: "Recovering…")
        let outcome: SalvageOutcome
        var recovered: TranscriptionResult?
        do {
            // Bound to this session BEFORE its drain (L review 98): reset, drain, build — as the resume does. What
            // the helper still holds is this session's (a pending retry attributed a stray helper's already) — unless
            // it holds a held session's capture: then nothing is drained (L review 167).
            await captureClient.adoptSession(sessionId: sessionId, directory: outputDir, drainHelper: drainHelper)
            // Drain capture diagnostics and stamp the always-present provenance into the
            // recovered transcript's metadata, same as a clean stop does (#154 finding 1) —
            // otherwise a recovered session's `sessionState.provenance` stays nil forever.
            // Built without draining, too, while the helper holds a held session's capture (L review 198): a build's drain
            // would pour that capture's events — its `captureStop` — into THIS session's record.
            let provenance = await captureClient.finalizeSessionDiagnostics(
                sessionId: sessionId,
                engine: config.engine.rawValue,
                recordingDirectory: outputDir,
                drainHelper: drainHelper
            )
            if let result = try await recoverChunkedSession(outputDirectory: outputDir, sessionId: sessionId, config: config,
                                                            transcriber: transcriber, diarizer: diarizer, provenance: provenance) {
                Logger.state.info("Recovered chunked session → \(result.jsonPath.lastPathComponent, privacy: .sensitive)")
                recovered = result
                // Chunks whose speech recognition failed are never called "transcribed" (R2 item 9, L review 93):
                // counted from the transcript just written, off the main actor. One that cannot be read back (or does
                // not answer) is never called transcribed either (L review 149). A rebuild names the damaged copy it
                // kept (L review 150).
                let jsonPath = result.jsonPath, damaged = scan.finalized == .damaged
                let read = await readOffMain("salvage: transcript", folder: outputDir) {
                    (SalvageOutcome.recognitionFailures(inTranscriptAt: jsonPath),
                     damaged ? Self.damagedCopy(of: sessionId, in: outputDir) : nil)
                }
                let failures = read?.0
                // The damaged copy is named only when the listing FOUND one (L review 190); a missing transcript had none.
                outcome = SalvageOutcome(kind: .transcriptWritten(result.jsonPath), chunkCount: chunkCount,
                                         recognitionFailures: failures ?? .init(), recognitionChecked: failures != nil,
                                         rebuiltKeeping: damaged ? read?.1 : nil,
                                         rebuilt: damaged ? .transcriptUnreadable : scan.finalized == .missing ? .transcriptMissing : nil)
                captureClient.commitSessionDiagnostics(sessionId: sessionId, directory: outputDir)   // L review 97
            } else {
                Logger.state.info("Chunked session had nothing to recover")
                if scan.finalized == .damaged {
                    // It WAS transcribed: its transcript is kept, only unreadable, with nothing to rebuild it from — never
                    // "could not be transcribed" (L review 150). Its evidence stays with it.
                    outcome = SalvageOutcome(kind: .transcriptUnreadable(outputDir.appendingPathComponent("\(sessionId).json")), chunkCount: chunkCount)
                } else if scan.finalized == .missing {
                    // It was transcribed, and its transcript is not there: said missing — never "kept" (L review 190).
                    outcome = SalvageOutcome(kind: .transcriptMissing(outputDir.appendingPathComponent("\(sessionId).json")), chunkCount: chunkCount)
                } else {
                    // Chunks on disk that produced nothing are kept, not "no recorded audio" (L round 5).
                    outcome = chunkCount > 0
                        ? SalvageOutcome(kind: .finalizeFailed("none of their audio could be processed"), chunkCount: chunkCount)
                        : SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0)
                    // Nothing on disk at all: nothing to keep evidence for. Chunks kept untranscribed keep theirs. Safe to
                    // commit with no transcript (L review 206): the record was BUILT above (`finalizeSessionDiagnostics`), so an
                    // anomalous session's `.diag.jsonl` is on disk — and one that could not be written keeps its live log
                    // through the commit's unwritten guard.
                    if chunkCount == 0 { captureClient.commitSessionDiagnostics(sessionId: sessionId, directory: outputDir) }
                }
            }
        } catch is FolderNotAnswering {
            // The folder stopped answering mid-salvage (L review 158): nothing was written, and the session waits — kept,
            // its folder said not to answer — never salvaged as failed.
            Logger.state.error("The salvage's folder did not answer — the session waits")
            if case .transcribing = appState.phase { appState.phase = .idle }
            await waitForUnansweringFolder(sentinel)
            return
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
        if sentinel.quitDuringFinalize, sentinel.salvageBegan {
            // Quit while an earlier launch recovered it (L review 194): the cause that salvage first saw, then the quit.
            message = RecoveryMessages.quitWhileRecovering(at: stoppedAt, outcome: outcome, cause: sentinel.stopCause ?? Self.relaunchCause(sentinel))
        } else if sentinel.quitDuringFinalize {
            message = RecoveryMessages.quitWhileFinishing(outcome: outcome)   // a quit, not a crash (L follow-up 42)
        } else if let held = sentinel.heldReason {
            // Held for the helper (L review 177): what happened, then that Parley kept it until the helper let go — never
            // "Parley crashed" for a capture that failed while Parley ran.
            message = RecoveryMessages.heldStopped(at: stoppedAt, outcome: outcome, held: held,
                                                   cause: sentinel.stopCause ?? Self.relaunchCause(sentinel))
        } else if outcome.kind == .nothingToSalvage, scan.legacyAudio {
            message = RecoveryMessages.relaunchStoppedKeepingOlderFormat(at: scan.legacyLastWrite.map { min($0, Date()) },
                                                                         folder: abbreviatedDisplayPath(outputDir.path))
        } else {
            // Why it stopped: as the launch that first kept it saw it — never the boot it is salvaged in (L reviews 69, 147).
            message = RecoveryMessages.relaunchStopped(at: stoppedAt, outcome: outcome, cause: sentinel.stopCause ?? Self.relaunchCause(sentinel))
        }
        // Only a written transcript is a recovery (L review 133): nothing to salvage, or chunks kept untranscribed,
        // are said on their own — never counted in "N earlier recordings were recovered".
        if case .transcriptWritten = outcome.kind {
            reportStopped(message, recovered: true, session: sentinel.sessionKey)
        } else {
            reportStopped(message, recovered: false, session: sentinel.sessionKey)
        }
        captureClient.captureEnded()
    }

    /// The slot's session is being salvaged (L review 194): the slot is stamped with the cause this launch first sees — first
    /// keeping wins, as the pending list's — and that a salvage began. A Quit during the salvage then leaves both beside its
    /// mark, so the next launch says the recording stopped for that cause and Parley was quit while recovering it — never
    /// only "quit". A slot already marked quit keeps what it says: that quit came during the user's own Stop.
    private func markSalvageBegan(_ sentinel: RecordingSentinel) {
        guard var slot = RecordingSentinel.read(directory: sentinelDirectory), slot.sessionKey == sentinel.sessionKey,
              !slot.salvageBegan, !slot.quitDuringFinalize else { return }
        slot.stopCause = slot.stopCause ?? sentinel.stopCause ?? Self.relaunchCause(slot)
        slot.salvageBegan = true
        do {
            try RecordingSentinel.write(slot, directory: sentinelDirectory)
        } catch {
            Logger.state.error("Could not mark the salvage on the recovery file: \(error, privacy: .private)")
        }
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
    /// 122). With no recovery file left, one is made from where the session is: the promise "Parley will finish it when
    /// the folder answers" is only ever made about something kept (L review 163).
    private func finishSentinel(after outcome: SalvageOutcome, sentinel: RecordingSentinel?, location: (outputDir: URL, sessionId: String)? = nil) {
        guard outcome.kind == .folderNotAnswering else {
            RecordingSentinel.delete(directory: sentinelDirectory)
            return
        }
        if let kept = RecordingSentinel.read(directory: sentinelDirectory) ?? sentinel ?? location.map({ Self.keptSentinel(for: $0) }) {
            keepPending(kept, markStopping: true, cause: .folderNotAnswering)
        } else {
            Logger.state.error("A session whose folder did not answer has no recovery file and no known folder — nothing could be kept")
        }
    }

    /// A recovery file for a session known only by where it is (L reviews 163, 188): salvage-only, alive until now — with
    /// the mic still marked for it, so a hold releases it once the helper lets go.
    nonisolated static func keptSentinel(for location: (outputDir: URL, sessionId: String),
                                         cause: RecordingSentinel.StopCause = .folderNotAnswering, micDeviceUID: String? = nil) -> RecordingSentinel {
        RecordingSentinel(startedAt: Date(), sessionName: location.sessionId,
                          systemAudioPath: location.outputDir.appendingPathComponent("\(location.sessionId)-0.wav").path,
                          micAudioPath: location.outputDir.appendingPathComponent("\(location.sessionId)-0_mic.wav").path,
                          micDeviceUID: micDeviceUID, lastAliveAt: Date(), bootSessionUUID: BootSession.currentUUID(), stopping: true,
                          stopCause: cause)
    }

    /// A stopped recording whose transcript must wait for its engine (L review 218): pending, salvage-only, and said once.
    private func keepForTheEngine(sentinel: RecordingSentinel?, location: (outputDir: URL, sessionId: String)?, why: String) {
        guard let kept = RecordingSentinel.read(directory: sentinelDirectory) ?? sentinel ?? location.map({ Self.keptSentinel(for: $0, cause: .userStopped) }) else {
            Logger.state.error("A stopped recording waits for its engine but has no recovery file and no known folder")
            return
        }
        keepPending(kept, markStopping: true, cause: .userStopped)
        let folder = abbreviatedDisplayPath(URL(fileURLWithPath: kept.systemAudioPath).deletingLastPathComponent().path)
        let message = RecoveryMessages.waitingForEngine(at: Date(), folder: folder, why: why)
        appState.errorMessage = message
        if saidWaitingForEngine.insert(kept.sessionKey).inserted {
            reportStopped(message, recovered: false, session: kept.sessionKey)
        }
    }

    /// The capture died and its restart could not be planned: the recording folder did not answer (L review 122).
    /// The recording ends — said so — and its recovery file is kept, salvage-only, for when the folder answers.
    private func endRecordingFolderNotAnswering(_ sentinel: RecordingSentinel) async {
        endRecordingFolderNotAnswering(sentinel, reason: "the capture stopped, and the recording folder isn’t answering, so it could not be restarted")
        await updateFolderAlarm()
    }

    private func endRecordingFolderNotAnswering(_ sentinel: RecordingSentinel, reason: String) {
        captureClient.captureEnded()
        awaitingRecoveryFrames = false
        transcriptionRunner.stopChunkRotation()
        transcriptionRunner.teardownChunkedPipeline()
        keepPending(sentinel, markStopping: true, cause: .folderNotAnswering)
        let message = "Recording failed — \(reason). Its audio is kept; the recording folder isn’t answering, and Parley will finish it when it answers."
        appState.criticalError = message
        appState.phase = .idle
        stopStatusPoll()
        notifyCritical("Recording Failed", message)
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
    /// sentinel is from another boot and was not stopping — the relaunch decision's `salvageStale`.
    nonisolated static func stoppedByRestart(_ sentinel: RecordingSentinel, currentBoot: String? = BootSession.currentUUID()) -> Bool {
        guard !sentinel.stopping, let recorded = sentinel.bootSessionUUID, let currentBoot else { return false }
        return recorded != currentBoot
    }

    /// Why THIS launch finds the recording stopped (L review 147): the Mac restarted, or Parley went. Stamped on a session
    /// when it is first kept pending, so a later launch — in another boot — never words a crash as a restart.
    nonisolated static func relaunchCause(_ sentinel: RecordingSentinel, currentBoot: String? = BootSession.currentUUID()) -> RecordingSentinel.StopCause {
        stoppedByRestart(sentinel, currentBoot: currentBoot) ? .restart : .appCrash
    }

    /// The damaged copy a rebuild kept (R2: `<id>.damaged.json`, or a unique name when that was taken): the newest.
    /// Reads the folder: only through `readOffMain`.
    nonisolated static func damagedCopy(of sessionId: String, in outputDir: URL) -> String? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? [])
            .filter { $0.hasPrefix("\(sessionId).damaged") && $0.hasSuffix(".json") }
        return names.max { a, b in
            let date = { (n: String) in (try? FileManager.default.attributesOfItem(atPath: outputDir.appendingPathComponent(n).path))?[.modificationDate] as? Date ?? .distantPast }
            return date(a) < date(b)
        }
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

    /// A test seam over the rebuild from disk: what `ChunkedSessionRecovery.recover` answers — nil being "the audio is
    /// kept, untranscribed" (L review 140).
    var recoverChunkedSessionForTesting: ((URL, String) async throws -> TranscriptionResult?)?

    /// The chunked session rebuilt from disk and transcribed (`ChunkedSessionRecovery.recover`); nil when nothing was
    /// transcribed — its audio, if any, kept.
    private func recoverChunkedSession(outputDirectory: URL, sessionId: String, config: Config, transcriber: any TranscriptionEngine,
                                       diarizer: (any DiarizationProvider)?, provenance: CaptureProvenance) async throws -> TranscriptionResult? {
        if let recoverChunkedSessionForTesting { return try await recoverChunkedSessionForTesting(outputDirectory, sessionId) }
        useFolderReadsForTheTranscript()
        return try await ChunkedSessionRecovery.recover(outputDirectory: outputDirectory, sessionId: sessionId, config: config,
                                                        transcriber: transcriber, diarizer: diarizer, runner: transcriptionRunner,
                                                        provenance: provenance, reads: folderReads, seconds: Self.seconds(folderReadDeadline))
    }

    /// The transcript's looks at its folder — and its writes (L review 185) — go through this coordinator's reader, with its
    /// bounds (L review 158).
    private func useFolderReadsForTheTranscript() {
        transcriptionRunner.folderReads = folderReads
        transcriptionRunner.folderReadSeconds = Self.seconds(folderReadDeadline)
        transcriptionRunner.folderWriteSeconds = Self.seconds(folderWriteDeadline)
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
                switch await readOffMain("salvage: last chunk", folder: outputDir, { FileManager.default.fileExists(atPath: wav) }) {
                case true?:
                    return SalvageOutcome(kind: outcome.kind, chunkCount: outcome.chunkCount, lastChunkKeptOnDisk: true,
                                          recognitionFailures: outcome.recognitionFailures)
                case nil:
                    // Unanswered: said so — "couldn't check the last chunk" — never silence (L review 163).
                    return SalvageOutcome(kind: outcome.kind, chunkCount: outcome.chunkCount,
                                          recognitionFailures: outcome.recognitionFailures, lastChunkUnchecked: true)
                case false?:
                    break
                }
            }
            return outcome
        case .finalizeFailed, .folderNotAnswering, .transcriptUnreadable, .transcriptMissing:
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
            recordingDirectory: outputDir,
            drainHelper: true
        )
        let kind: SalvageOutcome.Kind
        do {
            useFolderReadsForTheTranscript()
            let result = try await transcriptionRunner.finalize(
                sessionState: sessionState, outputDirectory: outputDir, config: configManager.config
            )
            appState.lastJsonPath = result.jsonPath.path
            appState.lastTranscriptPath = result.jsonPath.path
            Logger.state.info("Salvaged abandoned chunked session → \(result.jsonPath.lastPathComponent, privacy: .sensitive)")
            kind = .transcriptWritten(result.jsonPath)
            captureClient.commitSessionDiagnostics(sessionId: sessionState.sessionId, directory: outputDir)   // L review 97
        } catch is FolderNotAnswering {
            // Nothing could be written: the session is kept for when the folder answers (L review 158) — never "failed".
            Logger.state.error("Salvage finalize: the recording folder did not answer")
            kind = .folderNotAnswering
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
        await rotator.reconcileLateRotation()
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

/// A finalized session is never finalized again over its transcript (L review 197): it was already transcribed.
struct SessionAlreadyFinalized: Error, LocalizedError {
    let transcript: String
    var errorDescription: String? { "it was already transcribed to \(transcript), and Parley never writes over a finished transcript" }
}

/// The transcription engine is there, but not ready — its speech model is not downloaded (L review 178).
struct EngineNotReady: Error, LocalizedError {
    var errorDescription: String? { "its speech model is not downloaded" }
}

/// The Stop's rebuild could not get its transcription engine (L review 218): why, in words.
struct EngineUnavailable: Error, LocalizedError {
    let why: String
    var errorDescription: String? { why }
}

/// Whether the repair path has answered, shared by the capped wait and the answer (main actor).
@MainActor
private final class RepairAnswer {
    var arrived = false
}
