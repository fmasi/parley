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
    /// The Quit left a session HELD — the helper would not stop it (L review 223): the LaunchAgent stays installed, so the
    /// next launch finishes it. Decided from what is on disk at every exit of the Quit (L review 257).
    public internal(set) var keepsLaunchAgentOnQuit = false
    /// A session was held while the Quit waited (L review 223): what the Quit's decision falls back to when the recovery file
    /// does not answer its look (L review 257).
    var quitLeftAHeldSession = false
    /// The sessions whose helper has not let go (L reviews 257, 269): marked when a stop attempt BEGINS — the user's Stop, or
    /// any bounded helper stop — and cleared only when the helper let go (it handed back the files, answered that nothing was
    /// capturing, or went away) or once the session's hold is WRITTEN. So the refusal re-asks, and the gap before a hold, are
    /// counted too. The Quit's LaunchAgent keep reads it.
    var sessionsNotLetGo: Set<String> = []
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
    /// The session THIS process's `willPowerOff` marked (L review 221): the only mark its withdraw clears — a mark a dead
    /// earlier process left is final. Set where the mark lands, on the recovery file's queue (L review 235).
    let powerOffMark = PowerOffMark()
    /// The most a mark an exit makes waits for the recovery file (L review 235) — never past the exit's own deadline, and
    /// not at all once its queue is stuck. Tests shorten it.
    var exitMarkBound: Duration = .seconds(1)
    /// A Stop whose stopping mark did not answer, kept apart (L review 236): in its own file, written on its own queue — never
    /// the recovery file's, which is the one not answering — and, once that file is written, in memory (L review 265).
    var stopKeptApart: RecordingSentinel.StopRequest?
    /// The held sessions whose record already says why they were held (L review 268): said once per session.
    private var recordedWhyHeld: Set<String> = []
    /// The recording's session key (L review 266): set by its start, a resume and a re-attach — so a Stop always knows what to
    /// keep apart, even when the recovery file does not answer and no pipeline is running.
    var currentSessionKey: String?
    /// Where the Stop kept apart is written and read: a serial queue of its own (L review 236). Tests inject one.
    var stopRequestIO = SentinelIO(label: "eu.fmasi.parley.stop-request")
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
    /// outside a pass. Each with the session it is about (nil: none — a note about the pending list, say). `late`: the
    /// `audioAfterTranscript` messages — their own row, never under "Recording STOPPED" (L review 219).
    private var stoppedBatch: (recovered: [(session: String?, message: String)], other: [(session: String?, message: String)],
                               late: [(session: String?, message: String)], lists: [String],
                               revisions: [(stale: String, message: String)])?
    /// The sessions a pass already said are waiting for the transcription engine (L review 178), with what was said: said
    /// once per run, never again at every wake or mount while the engine is still not ready — only when its remedy changes
    /// (L review 255).
    private var saidWaitingForEngine: [String: (remedy: RecoveryMessages.EngineRemedy, message: String)] = [:]
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
    /// Called on the transition INTO a recording — a user's start, a relaunch's resume — once its phase is `.recording`:
    /// the app re-checks crash protection there, since the hand-over (an exit) cannot happen under a recording (final
    /// review A-I2).
    public var onRecordingStarted: (() -> Void)?
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

        // Capped (L review 262): every file named from the session — its summary, its records — fits in 255 bytes.
        let sanitized = fittedFilename(sanitizeFilename(sessionName), maxBytes: maxSessionIdBytes - timestamp.utf8.count - 1)
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
        noteRecordingRoot()
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
            // Only this read's own bound ran out — an earlier read of the folder is joined, never taken for an answer (L review
            // 210): not answering, never "not reachable".
            Logger.state.error("Recording not started: the recording folder did not answer")
            refuseStart("The recording folder isn’t answering — is its drive or network share still available? (\(folderName))")
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
        // The mic marked before this start (a held session's, say): put back if the helper was busy with it, or never asked.
        // Read before anything can fail (final review A-M5): a failed slot write must not read as "nothing was marked".
        let micBefore = recordingMicrophone.current
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
            // Off the main actor, within what is left of the start's deadline (L review 217).
            try await slotWriteOffMain(sentinel, "start: write", seconds: Self.seconds(until: startBy))
            startedSentinel = sentinel
            currentSessionKey = sentinel.sessionKey   // L review 266

            // Before the helper opens the mic, so no meter opens it meanwhile (#192).
            setHelperMic(microphoneDeviceId)
            helperStartIssued = true
            let baseName = naming.baseName, sessionId = naming.chunkBaseName
            // A start on a specific mic is the user's choice: remembered for later recordings (#315). This
            // start passes the EARLIER choices (its own snapshot); the helper adds the mic it starts on itself.
            rememberMicrophoneChoice(microphoneDeviceId)
            let source = config.systemAudioSource, options = CaptureOptions(config: config)
            // Bounded by what is left of the start's deadline; a start that answers later changes nothing.
            try await bounded("start", seconds: Self.seconds(until: startBy)) {
                try await self.startHelper(outputDirectory: outputDir, baseName: baseName, microphoneDeviceId: microphoneDeviceId,
                                           systemAudioSource: source, options: options, sessionId: sessionId)
            }
            captureStarted = true

            useFolderReadsForTheTranscript()   // the pipeline's session.json writes: this reader, its bound (L review 234)
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
            onRecordingStarted?()
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
            let helperStop = await stopAfterFailedStart(captureStarted: captureStarted, startIssued: helperStartIssued,
                                                        error: error, label: "stop after failed start",
                                                        session: Self.sessionKey(of: (outputDir, naming.chunkBaseName)))
            let helperLetGo = helperStop.letGo
            captureClient.captureEnded()   // the recording never began: disarm crash detection (C1)
            if reply == .alreadyCapturing {
                // What the refused start drained is the busy capture's: to the pending session that knows it (L review 157).
                await captureClient.attributeRefusedStartDrain(toOneOf: pendingSessions().map {
                    (sessionId: stripSegmentSuffix($0.systemAudioPath), directory: URL(fileURLWithPath: $0.systemAudioPath).deletingLastPathComponent())
                })
            }
            if helperLetGo {
                // A busy helper still holds the mic of the capture it is busy with: that marker stays (#192). So does the marker
                // of a start that failed before it asked the helper for anything (final review A-M5): a held session's helper
                // may still hold that mic.
                if reply == .alreadyCapturing || !helperStartIssued { restoreHelperMic(micBefore) } else { clearHelperMic() }
                await slotDeleteOffMain("start: delete")
                // No recording exists: no evidence of one either — never an orphan live log (L11 review 68).
                captureClient.discardSessionEvidence(sessionId: naming.chunkBaseName, directory: outputDir)
            } else {
                // The helper may still be capturing, and hold the mic (L follow-up 27): HELD (L review 81) —
                // salvage-only, out of the slot the next Start writes, the mic kept marked — and finished once
                // the helper's stop says it let go. From the slot, or — it cannot be read back — from what this start
                // wrote there (L review 132): never a marked mic with nothing left to release it.
                let slot = await slotReadOffMain("start: read")
                if slot == nil { Logger.state.error("A failed start's recovery file cannot be read back — holding its session from the start's own copy") }
                Logger.state.error("A failed start left the capture helper unanswered — holding its session")
                if let held = slot ?? startedSentinel {
                    holdForHelper(held, message: "Parley couldn’t stop the capture of the recording that failed to start — its audio is kept, and Parley will finish it once the capture helper lets go.",
                                  cause: .startFailed, reason: .startFailed, because: helperStop.because)
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
        rememberMicrophoneChoice(deviceId)
        // The recording ended normally while the helper was switching (Stop during the switch): there
        // is no recovery file to update any more, and nothing to warn about. Stop deletes the sentinel
        // and leaves the recording phase in one synchronous step, so this check can't fall between.
        guard appState.isRecording else { return }
        // The switch itself worked. If the recovery file can't record it — unwritable, or missing
        // (deleted mid-recording) — a crash restart would resume on the mic the user left, possibly the
        // dead one they switched away from. Say so rather than stay silent.
        guard var sentinel = slotRead() else {
            Logger.state.error("Could not record the switched mic: the recovery file is missing during a live recording")
            warnRecoveryNotUpdated()
            return
        }
        sentinel.micDeviceUID = deviceId
        do {
            try slotWrite(sentinel)
        } catch {
            Logger.state.error("Could not record the switched mic in the sentinel: \(error, privacy: .private)")
            warnRecoveryNotUpdated()
        }
    }

    /// Remember an input the user chose by hand (#315). Written only when it changes the list.
    private func rememberMicrophoneChoice(_ deviceId: String?) {
        let recent = configManager.config.recentMicrophoneDeviceIds ?? []
        let updated = MicTargeting.rememberingUserChoice(deviceId, in: recent)
        guard updated != recent else { return }
        configManager.update { $0.recentMicrophoneDeviceIds = updated }
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
            // The user's Stop, already: a crash before the deferred stop runs is salvaged, never resumed. Queued on the
            // recovery file's queue, off the main actor, never awaited (L review 217): nothing here may suspend before the
            // phase says the Stop, or the restart could honour it first.
            let directory = sentinelDirectory
            sentinelIO.enqueue("mark stopping") { Self.markStopping(directory: directory) }
            // That mark is never waited for, so the stop is always kept apart too — queued on its own queue (L review 266).
            keepStopApartQueued(session: currentSessionKey ?? transcriptionRunner.chunkRotator.map { Self.sessionKey(of: $0.sessionLocation) })
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
        // No rotation may race the helper's stop (council B-I3): the timer stops — first, before the recovery file's awaits
        // below — and a rotation already in flight completes, bounded, before the helper is asked.
        transcriptionRunner.stopChunkRotation()
        // Read ONCE, before the stop: a successful stop deletes it, and the catch below must still know
        // where the session is (L6 fix round 1). Off the main actor (L review 217).
        let sentinel = await slotReadOffMain("stop: read")
        // BEFORE asking the helper (§8.8): a crash during the stop or its finalize must be salvaged at
        // relaunch, never resume a recording the user stopped — kept apart when the mark does not answer (L review 236).
        await markSentinelStoppingOffMain(session: sentinel?.sessionKey ?? transcriptionRunner.chunkRotator.map { Self.sessionKey(of: $0.sessionLocation) })
        // Its looks included (L review 208): a rotation that has not sent its rotate never will, now the rotator is stopped.
        let rotationBound = transcriptionRunner.chunkRotator?.rotationBoundSeconds ?? ChunkRotator.rotateCallSeconds
        _ = try? await withDeadline(seconds: rotationBound, label: "rotation before stop") { await self.awaitRotationInFlight() }
        var stoppedPaths: AudioPaths?
        // The recording this Stop's attempt marks not let go (L review 269): the one key its hold, if any, also clears.
        let attemptKey = sentinel?.sessionKey ?? transcriptionRunner.chunkRotator.map { Self.sessionKey(of: $0.sessionLocation) } ?? currentSessionKey
        do {
            // Bounded (§8.8): a helper that never answers is salvaged from disk in the catch below. A stop already under
            // way in the helper is waited for, within the same deadline (L review 148).
            let paths = try await userStop(session: attemptKey)
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
                // The last chunk, then any background chunks still processing — bounded (#226): chunks that do not finish
                // (a recording folder that stopped answering under them) keep the session for later, never the Stop waiting.
                guard await chunksProcessed(by: processor, session: attemptKey, during: "stop", lastChunk: lastChunk) else {
                    throw FolderNotAnswering()
                }

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
                    // The engine first, as a launch salvage checks it (L reviews 178, 218, 232): one that cannot be made — or
                    // whose models are not there while there is audio to recognise — keeps the session pending, never "could
                    // not be transcribed" and forgotten.
                    let transcriber: any TranscriptionEngine, diarizer: (any DiarizationProvider)?
                    do {
                        (transcriber, diarizer) = try await enginesForSalvage(config: config, toRecognise: look.toRecognise)
                    } catch {
                        throw EngineUnavailable(why: error.localizedDescription, remedy: Self.engineRemedy(for: error, engine: config.engine))
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

            // Only now: the transcript exists (or there was nothing to write). The stop kept apart goes with the recovery file —
            // only once its delete answered (L review 236).
            // Whatever kept it apart — this Stop's mark, or a Stop deferred during a crash restart (L reviews 266, 267).
            if await slotDeleteOffMain("stop: delete"), let key = sentinel?.sessionKey ?? stopKeptApart?.sessionKey ?? currentSessionKey {
                dropStopKeptApart(for: key)
            }
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
                if let held = await slotReadOffMain("stop: read") ?? sentinel
                    ?? location.map({ Self.keptSentinel(for: $0, cause: .stopInterrupted, micDeviceUID: marked ?? nil) }) {
                    if sentinel == nil { Logger.state.error("The held Stop's session has no recovery file — held from where its pipeline was") }
                    if holdForHelper(held, message: message, cause: .stopInterrupted, reason: .stopUnderWay,
                                     because: "the Stop found another stop still under way in the capture helper") {
                        stopAttemptEnded(attemptKey)   // the key the attempt marked, whatever the hold was read back as (L review 269)
                    }
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
            // crash meanwhile is salvaged at relaunch. Any other stop failure (an XPC crash) means the helper
            // has already gone.
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
                keepForTheEngine(sentinel: sentinel, location: location, why: waiting.why, remedy: waiting.remedy)
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
            await finishSentinel(after: outcome, sentinel: sentinel, location: location)
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
        // — both keep recording silently. A give-up on the remote stream is an alarm, not a crash.
        // Routine mic switches are handled by onMicDeviceChanged (label refresh only, no banner) —
        // for recordings this coordinator started and the ones it re-attached at launch alike.
        captureClient.onMicDeviceChanged = { [weak self] deviceId in
            Task { @MainActor in
                guard let self, self.appState.isRecording else { return }
                self.setHelperMic(deviceId)
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

    /// A crash of the helper. While a start awaits it the phase is still `.idle`: the
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
        // Every restart lost audio — a helper restart, a relaunch's resume, a wake — and records its gap (final review
        // R-I1): never "Resumed" as if nothing was lost.
        appState.interruptionWarning = "Recording was briefly interrupted. Some audio may have been lost."
        notify("Recording Resumed", "Recording was briefly interrupted. Some audio may have been lost.")
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

    /// A stop attempt of `session` begins (L review 269): its helper has not let go until it does, or its hold is written.
    private func stopAttemptBegins(_ session: String?) {
        if let session { sessionsNotLetGo.insert(session) }
    }

    /// `session`'s helper let go, or its hold is written (L review 269).
    private func stopAttemptEnded(_ session: String?) {
        if let session { sessionsNotLetGo.remove(session) }
    }
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
        // (L review 195). Only a flush that had a real budget says so (L review 244): one whose exit's deadline was all but
        // spent before it began says nothing about the folder.
        guard !finished else { return }
        if bound >= Self.exitFlushRealBudget {
            Logger.state.error("The exit's flush of the live logs ran out of its bound — a recording folder is not answering")
            exitFlushTimedOut = true
        } else {
            Logger.state.error("The exit's flush had no budget left — the app's own last flush still runs")
        }
    }

    /// The least budget whose running out says the folder is not answering (L review 244).
    static let exitFlushRealBudget: Duration = .milliseconds(100)

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
    ///
    /// `session`: the recording the helper is asked to let go of (L review 269) — not let go from here until it does, or its
    /// hold is written (`holdForHelper`).
    private func boundedHelperStop(_ label: String, session: String?) async -> HelperStopAnswer {
        stopAttemptBegins(session)
        let deadline = SuspendingClock.now + helperStopDeadline
        while true {
            do {
                try await bounded(label, seconds: Self.seconds(until: deadline)) { try await self.stopHelper() }
                stopAttemptEnded(session)
                return .released
            } catch is CaptureCallTimeout {
                Logger.state.error("The capture helper did not stop (\(label, privacy: .public)) — it may still be capturing; dropping the connection")
                captureClient.dropConnection()
                return .heldOn(because: "its stop timed out (\(label))")
            } catch {
                switch Self.helperReply(error.localizedDescription) {
                case .notCapturing, .startCancelled:
                    stopAttemptEnded(session)
                    return .released   // nothing is capturing: it has let go
                case .stopping where SuspendingClock.now + stopReaskInterval < deadline:
                    Logger.state.info("The capture helper is already stopping (\(label, privacy: .public)) — asking again shortly")
                    try? await Task.sleep(for: stopReaskInterval)
                    continue
                default:
                    Logger.state.error("The capture helper's stop failed (\(label, privacy: .public)): \(error, privacy: .private)")
                    captureClient.record(.streamStopError, .anomaly, ["source": "app", "call": label, "error": error.localizedDescription])
                    return .heldOn(because: "its stop failed (\(label)): \(Self.describe(error))")
                }
            }
        }
    }

    /// What a bounded helper stop found (L reviews 27, 247): it let go — or it held on, and why, in words: what the held
    /// session's record says when it is finally finished.
    enum HelperStopAnswer: Equatable {
        case released
        case heldOn(because: String)
        var letGo: Bool { self == .released }
        var because: String? { if case .heldOn(let why) = self { return why } else { return nil } }
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
    ///
    /// `session`: the recording (L review 269) — not let go from the first ask until the helper hands back its files, or goes
    /// (any failure but a timeout or a refusal), or its hold is written. A timeout leaves it marked: the connection is dropped,
    /// and nothing confirmed the helper let go.
    private func userStop(session: String?) async throws -> AudioPaths {
        stopAttemptBegins(session)
        let deadline = SuspendingClock.now + stopDeadline
        var refusal: Error?
        while true {
            do {
                let paths = try await bounded("stop", seconds: Self.seconds(until: deadline)) { try await self.helperStop() }
                stopAttemptEnded(session)
                return paths
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
            } catch {
                stopAttemptEnded(session)   // nothing is capturing, or the helper is gone: it let go
                throw error
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
    private func stopAfterFailedStart(captureStarted: Bool, startIssued: Bool, error: Error, label: String,
                                      session: String?) async -> HelperStopAnswer {
        guard captureStarted || (startIssued && error is CaptureCallTimeout) else { return .released }
        return await boundedHelperStop(label, session: session)
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
        // Whether this crash came during a recording (L review 264): its phase then refuses any Start until this recovery
        // ends the recording — read before the first await.
        let wasRecording = appState.isRecording
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

        guard let sentinel = await slotReadOffMain("crash: read") else {
            Logger.state.error("No sentinel found during crash recovery")
            // The recording's own capture (L reviews 242, 264): a recording's phase refused any Start during the read. A crash
            // reported with no recording running ends the capture only if no Start got in meanwhile.
            if wasRecording { captureClient.captureEnded() } else { endCaptureIfStillOwned() }
            // No recovery file to restart from, but a live pipeline still knows its session: salvage it
            // there (the rotation stops, the pipeline is torn down) — never leave it running behind an idle
            // app (L follow-up 28).
            // What is said follows what was looked at (L review 87): the salvage's outcome when a pipeline knew
            // the session — never "no recovery data" beside a transcript it wrote — and no claim at all when
            // nothing could be looked at.
            if let location = transcriptionRunner.chunkRotator?.sessionLocation {
                let outcome = await finalizeAbandonedSession(at: location, reingestOrphan: true)
                // "Parley will finish it when the folder answers" — so it is kept (L review 163).
                await finishSentinel(after: outcome, sentinel: nil, location: location)
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
            // A crash verdict can be false (final review AF-11, A-I1's class): the helper may still be capturing this session,
            // writing its live chunk. Stopped, bounded, BEFORE anything reads its files, as a failed restart's is; one that does
            // not let go holds the session untranscribed, its mic kept marked, for the pending retry to finish.
            let helperStop = await boundedHelperStop("stop at the retry cap", session: sentinel.sessionKey)
            guard helperStop.letGo else {
                await settleAbandonedPipeline()
                // Read BEFORE the phase goes idle (L review 264), as the failed restart's hold does.
                let held = await slotReadOffMain("crash: read") ?? sentinel
                appState.criticalError = "Recording failed — capture crashed repeatedly. Its audio is kept; Parley will transcribe the recording once the capture helper lets go."
                appState.phase = .idle
                stopStatusPoll()
                keepMicMarked = true
                Logger.state.error("The capture helper did not let go at the retry cap — holding its session, untranscribed")
                holdForHelper(held,
                              message: "Parley couldn’t stop the capture after it crashed repeatedly — its audio is kept, and Parley will transcribe it once the capture helper lets go.",
                              cause: .captureFailed, reason: .restartFailed, because: helperStop.because)
                notifyCritical("Recording Failed", appState.criticalError ?? "")
                return
            }
            // council F3: salvage the live chunked session (re-ingesting the in-progress orphan,
            // since this branch returns before the normal re-ingestion below) so chunks already
            // transcribed aren't discarded with the session.
            let outcome = await finalizeAbandonedSession(at: Self.location(of: sentinel), reingestOrphan: true)
            appState.criticalError = "Recording failed — capture crashed repeatedly. " + RecoveryMessages.outcomeSentence(outcome)
            appState.phase = .idle
            stopStatusPoll()
            await finishSentinel(after: outcome, sentinel: sentinel)
            // §7.4 P6: says what the salvage actually wrote — never "has been transcribed" when nothing was.
            notifyCritical("Recording Failed", RecoveryMessages.recordingFailed(after: outcome))
            return
        }

        let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        let baseName: String
        var newSentinel: RecordingSentinel
        // The orphaned in-progress chunk, located before the rotator advances and processed only once nothing may still
        // write it: after the restart's start, or after a failed restart's helper let go (final review A-I1).
        var pendingOrphan: (chunk: ChunkRotator.FinalizedChunk, processor: ChunkProcessor)?
        // When the helper last wrote the orphan — the crash, as the relaunch reads it (its WAVs' mtime): the restart's gap
        // starts there (final review R-I1). Nil when there is no live file, or the folder did not answer.
        var orphanLastWrittenAt: Date?

        // #92: when the chunked pipeline is still live (the common live-crash case), locate the orphaned
        // in-progress chunk and advance the rotator BEFORE restarting capture. Otherwise the orphan's audio
        // is processed by no one and silently dropped from the final transcript.
        if let rotator = transcriptionRunner.chunkRotator,
           let processor = transcriptionRunner.chunkProcessor {
            let orphan = await locateOrphanChunk(rotator: rotator, outputDir: outputDir)
            pendingOrphan = (orphan, processor)
            let orphanFiles = [orphan.systemPath, orphan.micPath]
            orphanLastWrittenAt = await readOffMain("crash: orphan mtime", folder: outputDir, {
                orphanFiles.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max()
            }) ?? nil
            let plan = await rotator.recoverFromCrash()
            let restart = Self.liveRestartPlan(sentinel: sentinel, recoveryPlan: plan, outputDir: outputDir)
            baseName = restart.baseName
            newSentinel = restart.newSentinel
            Logger.state.info("Orphan chunk \(orphan.index, privacy: .public) located; recovery continues at \(baseName, privacy: .sensitive)")
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
            // The restart's start succeeded, so the helper that wrote the orphan is gone: it is sealed (A-I1).
            if let orphan = pendingOrphan {
                pendingOrphan = nil
                orphan.processor.processChunk(orphan.chunk)
            }
            // The helper died and was restarted: the audio between its last write and this start is recorded nowhere
            // (final review R-I1). Said the way the relaunch says its gap: evidence + session, awaited so nothing ends
            // the recording under it; "Resumed" says audio may have been lost (`noteFirstFrames`).
            let gapEnd = Date()
            let gapStart = orphanLastWrittenAt.map { min($0, lastCrashAt ?? $0) } ?? lastCrashAt ?? gapEnd
            captureClient.record(.captureGap, .anomaly, ["start": gapStart.ISO8601Format(), "end": gapEnd.ISO8601Format(), "reason": "helper restart"])
            await transcriptionRunner.recordCaptureGap(CaptureGap(start: gapStart, end: gapEnd, reason: "helper restart"))
            newSentinel.lastAliveAt = Date()
            // A Stop deferred during this restart already marked the sentinel; the rewrite keeps the mark.
            newSentinel.stopping = newSentinel.stopping || stopRequestedDuringRecovery
            try await slotWriteOffMain(newSentinel, "crash: write")
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
                _ = await boundedHelperStop("stop after an abandoned restart", session: nil)
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
            // The helper refused the restart because it is STILL capturing — this session's own capture: a crash verdict
            // can be false (final review A-I1). It never let go: stop it, bounded, so its files are sealed before anything
            // reads them; not letting go holds the session below — never a transcript over a file it still writes.
            let refusedAsBusy = Self.helperReply(error.localizedDescription) == .alreadyCapturing
            let helperStop = await stopAfterFailedStart(captureStarted: captureStarted || refusedAsBusy, startIssued: startIssued,
                                                        error: error, label: refusedAsBusy ? "stop after a refused restart" : "stop after failed restart",
                                                        session: sentinel.sessionKey)
            let helperLetGo = helperStop.letGo
            guard helperLetGo else {
                // It may still be capturing — the restart's own capture, into THIS session — and hold the mic: HELD
                // (L review 81), salvage-only, never resumed. Nothing is transcribed now (L review 137): a transcript
                // written while the helper still writes would leave its later audio out. The chunks processed so far
                // are in session.json; the salvage, once the helper lets go, transcribes everything once.
                await settleAbandonedPipeline()
                // Read BEFORE the phase goes idle (L review 264): from there to the hold nothing awaits, so no Start gets in
                // before the hold ends this capture.
                let held = await slotReadOffMain("crash: read") ?? sentinel
                appState.criticalError = "Recording failed — could not restart capture: \(Self.describe(error)). Its audio is kept; Parley will transcribe the recording once the capture helper lets go."
                appState.phase = .idle
                stopStatusPoll()
                keepMicMarked = true
                Logger.state.error("A failed restart left the capture helper unanswered — holding its session, untranscribed")
                holdForHelper(held,
                              message: "Parley couldn’t stop the capture after the failed restart — its audio is kept, and Parley will transcribe it once the capture helper lets go.",
                              cause: .captureFailed, reason: .restartFailed, because: helperStop.because)
                notifyCritical("Recording Failed", appState.criticalError ?? "")
                return
            }
            // The helper let go: the orphan is sealed now, and joins the salvage (final review A-I1). Not in the HELD branch
            // above — the salvage that runs once the helper lets go finds it on disk and transcribes everything once.
            if let orphan = pendingOrphan {
                pendingOrphan = nil
                orphan.processor.processChunk(orphan.chunk)
            }
            // council F3: the orphan is re-ingested now, so just finalize what's been processed
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
            await finishSentinel(after: outcome, sentinel: sentinel)
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
        noteRecordingRoot()
        if gateReservedForLaunch {
            gateReservedForLaunch = false   // held for this since the coordinator was made (L review 131)
        } else {
            // A retry that won the race to the gate finishes first.
            await awaitSettled { !$0.recoveryGateHeld }
            recoveryGateHeld = true
        }
        stoppedBatch = ([], [], [], [], [])
        let slot = slotRead()
        clearStaleStopRequest(keeping: slot?.sessionKey)   // L review 267
        if let sentinel = slot {
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
    /// key), nil for a note about no one session. `replacing`: what this session's row said before, now stale (L review
    /// 255) — replaced, never left beside the new message.
    private func reportStopped(_ message: String, recovered: Bool, session: String? = nil, replacing stale: String? = nil) {
        if let batch = stoppedBatch {
            // Said once per pass, however many times the pass looks (L review 130) — deduplicated by SESSION, never by the
            // text alone: two sessions whose rows read the same are both said (L review 180).
            let entry = (session: session, message: message)
            if let stale {
                // Said by an earlier pass, its row still up: revised in place when this pass's row is raised.
                if appState.activeAlarms[.recordingStopped]?.message.contains(stale) == true {
                    stoppedBatch?.revisions.append((stale, message))
                    return
                }
                stoppedBatch?.recovered.removeAll { $0.session == session && $0.message == stale }
                stoppedBatch?.other.removeAll { $0.session == session && $0.message == stale }
            }
            guard !(batch.recovered + batch.other).contains(where: { $0.session == entry.session && $0.message == entry.message }) else { return }
            if recovered { stoppedBatch?.recovered.append(entry) } else { stoppedBatch?.other.append(entry) }
            return
        }
        if let stale, appState.activeAlarms[.recordingStopped]?.message.contains(stale) == true {
            appState.reviseAppAlarm(.recordingStopped, replacing: stale, with: message)
            presentAlarms(reshow: [.recordingStopped])
            return
        }
        presentAlarms(reshow: raiseSessionRow(.recordingStopped, message: message))
    }

    /// A per-session row raised (L review 261): another recording's message, while the row is still up, is added to it —
    /// and that row is presented again (returned, for `presentAlarms(reshow:)`), never dropped.
    private func raiseSessionRow(_ kind: AlarmKind, message: String) -> Set<AlarmKind> {
        raiseSessionRow(kind, parts: [message])
    }

    /// A pass's row, part by part (L review 271): added to a row still up, only the sentences it does not say yet.
    private func raiseSessionRow(_ kind: AlarmKind, parts: [String]) -> Set<AlarmKind> {
        let wasUp = appState.activeAlarms[kind] != nil
        return appState.raiseAppAlarm(kind, parts: parts) && wasUp ? [kind] : []
    }

    /// Audio recorded after a finished recording's transcript (L reviews 137, 219): its own acknowledgeable row, "Audio kept
    /// after a transcript" — nothing just stopped. Batched in a pass as `reportStopped` is.
    private func reportAudioAfterTranscript(_ message: String, session: String?) {
        if let batch = stoppedBatch {
            let entry = (session: session, message: message)
            guard !batch.late.contains(where: { $0.session == entry.session && $0.message == entry.message }) else { return }
            stoppedBatch?.late.append(entry)
            return
        }
        presentAlarms(reshow: raiseSessionRow(.audioAfterTranscript, message: message))
    }

    /// A note about the pending list itself — one Parley could not read (L review 249): its own row, `pendingListUnreadable`,
    /// never "Recording STOPPED", where it would take the place of a session's own row. Batched in a pass as the others are.
    private func reportPendingListNote(_ message: String) {
        if let batch = stoppedBatch {
            guard !batch.lists.contains(message) else { return }
            stoppedBatch?.lists.append(message)
            return
        }
        appState.raiseAppAlarm(.pendingListUnreadable, message: message)
        presentAlarms()
    }

    /// One row for everything a recovery pass has to say (L review 90): "N earlier recordings were recovered: …".
    private func flushStoppedBatch() {
        guard let batch = stoppedBatch else { return }
        stoppedBatch = nil
        if !batch.lists.isEmpty {
            appState.raiseAppAlarm(.pendingListUnreadable, message: batch.lists.joined(separator: " "))
        }
        var parts: [String] = []
        if batch.recovered.count == 1 {
            parts.append(batch.recovered[0].message)
        } else if batch.recovered.count > 1 {
            parts.append("\(batch.recovered.count) earlier recordings were recovered: " + batch.recovered.map(\.message).joined(separator: " "))
        }
        parts += batch.other.map(\.message)
        var reshow: Set<AlarmKind> = []
        for revision in batch.revisions where appState.reviseAppAlarm(.recordingStopped, replacing: revision.stale, with: revision.message) {
            reshow.insert(.recordingStopped)   // L review 255: a stale remedy replaced, and said again
        }
        if !batch.late.isEmpty {
            reshow.formUnion(raiseSessionRow(.audioAfterTranscript, parts: batch.late.map(\.message)))
        }
        guard !parts.isEmpty else {
            if !batch.late.isEmpty || !batch.lists.isEmpty || !reshow.isEmpty { presentAlarms(reshow: reshow) }
            return
        }
        reshow.formUnion(raiseSessionRow(.recordingStopped, parts: parts))
        presentAlarms(reshow: reshow)
    }

    private enum RelaunchOutcome { case handled, heldForHelper }

    /// After every await of a relaunch step (L follow-up 38, L reviews 112, 129, 161): a Start that got in meanwhile — the
    /// user's, announced or running — owns the app, so the session waits for the next idle — pending, retried then — and
    /// nothing here touches that start (not its phase, not its crash detection). Checked BEFORE anything disarms or arms
    /// crash detection. False when it yielded.
    /// `keptWhileWriting`: why the caller keeps the session (L review 258) — kept with it here too, never dropped by this keep.
    private func stillOwnsTheSession(_ sentinel: RecordingSentinel, keptWhileWriting: RecordingSentinel.KeptWhileWriting? = nil) -> Bool {
        guard !appState.isIdle || userStartInFlight else { return true }
        Logger.state.info("A recording start is in flight — the relaunch session waits")
        keepPending(sentinel, keptWhileWriting: keptWhileWriting)
        retryPendingWhenIdle = true
        return false
    }

    /// The ONE way a relaunch, salvage or pending step ends the capture it settled (L reviews 129, 242): crash detection is
    /// disarmed only while no Start owns the app. One that got in during an await armed it for ITS capture, and keeps it —
    /// the step's own bookkeeping (a commit, a forget, a row) still happens. Used at every such `captureEnded` that follows
    /// an await. The recording's own paths — a start's failure, a crash recovery, a hold — end their own capture: nothing
    /// else can start one while they run (`startRunning`, a recording phase), and a relaunch's hold is only ever reached
    /// through `stillOwnsTheSession`.
    private func endCaptureIfStillOwned() {
        guard appState.isIdle, !userStartInFlight else {
            Logger.state.info("A recording start got in meanwhile — its crash detection is left armed")
            return
        }
        captureClient.captureEnded()
    }

    private func recover(_ found: RecordingSentinel) async -> RelaunchOutcome {
        var sentinel = found
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
        // A Stop whose stopping mark never landed, kept apart (L review 236): that recording is stopping — never resumed.
        let stopRequestedAt = sentinel.stopping ? nil : await stopRequestedAt(for: sentinel)
        // Off the main actor, bounded (L review 75): a folder that does not answer is unreachable here — the
        // session waits, never salvaged as "no recorded audio".
        let probe = folderProbe
        let read = await readOffMain("relaunch: recording folder", folder: outputDir) { Self.folderStatus(outputDir, probe: probe) }
        // No answer within its own bound: the session waits, its folder said NOT ANSWERING — never "not reachable" (L review 210).
        if read == nil { foldersNotAnswering.insert(sentinel.sessionKey) }
        let folderStatus = read ?? .unreachable
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
            let helperStop = await boundedHelperStop("stop an unanswering helper at relaunch", session: sentinel.sessionKey)
            guard stillOwnsTheSession(sentinel) else { return .handled }   // L review 112: after every await
            if !helperStop.letGo {
                holdForHelper(sentinel, because: helperStop.because)
                return .heldForHelper
            }
        }
        let helperCapturing = helperState == .capturing
        let decision = RelaunchDecision.decide(
            lastAliveAt: sentinel.lastAliveAt, bootSessionUUID: sentinel.bootSessionUUID, wasStopping: sentinel.stopping,
            now: Date(), helperCapturing: helperCapturing, currentBootSessionUUID: BootSession.currentUUID(),
            folderReachable: folderStatus == .reachable, stopRequestedAt: stopRequestedAt)
        Logger.state.info("Relaunch decision: \(String(describing: decision), privacy: .public)")
        // Every step from here keeps it salvage-only — a keeping, a wait for its folder (L review 236).
        if RelaunchDecision.stopWasRequested(lastAliveAt: sentinel.lastAliveAt, stopRequestedAt: stopRequestedAt) {
            Logger.state.info("The recording was stopped, its stopping mark never landed — it is stopping, never resumed")
            sentinel.stopping = true
        }

        switch decision {
        case .reattach:
            Logger.state.info("XPC service alive — re-attaching (Flow A)")
            // The session's folder, read off the main actor BEFORE the recording is re-attached (L review 75).
            let scan = await readOffMain("re-attach: session folder", folder: outputDir) { [sentinel] in Self.scanForReattach(sentinel: sentinel, outputDir: outputDir) }
            // A Start pressed during the read owns the app now (as after the ping).
            guard stillOwnsTheSession(sentinel) else { return .handled }
            if scan?.finalized == true {
                // Already transcribed — a held restart's helper went on writing it: never re-attached, which would
                // finalize it a second time over its transcript (L review 157). The capture is stopped (bounded); the
                // salvage then cleans up and says what was recorded after the transcript (L review 137).
                Logger.state.info("The capturing session was already transcribed — stopping its capture, never re-attached")
                let helperStop = await boundedHelperStop("stop the capture of a finished session", session: sentinel.sessionKey)
                guard stillOwnsTheSession(sentinel) else { return .handled }
                if !helperStop.letGo {
                    holdForHelper(sentinel, because: helperStop.because)
                    return .heldForHelper
                }
                relaunchProbing = false
                await salvageAtLaunch(sentinel: sentinel, outputDir: outputDir, helperJustLetGo: true)   // L review 248
                return .handled
            }
            // From here to the adopt, all synchronous (L review 72): a crash or a Stop can only arrive once the
            // chunk pipeline exists — the crash path then names its restart from the live rotator, and a Stop
            // finishes the recording once, on the live pipeline (the orphans are already queued in it).
            appState.phase = .recording(since: sentinel.startedAt)
            currentSessionKey = sentinel.sessionKey   // L review 266
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
                let helperStop = await boundedHelperStop("stop after relaunch", session: sentinel.sessionKey)
                // A Start that got in during the stop owns the app now (L review 112): the session waits.
                guard stillOwnsTheSession(sentinel) else { return .handled }
                if !helperStop.letGo {
                    holdForHelper(sentinel, because: helperStop.because)
                    return .heldForHelper
                }
            }
            relaunchProbing = false   // the helper let go: a salvage is no start (L review 159)
            // A recording that was stopping: the helper was stopped just now — its events are this session's (L review 248).
            await salvageAtLaunch(sentinel: sentinel, outputDir: outputDir, helperJustLetGo: reason == .wasStopping)
        case .salvageStale:
            relaunchProbing = false
            await salvageAtLaunch(sentinel: sentinel, outputDir: outputDir)
        case .waitForFolder:
            // A stopping session's helper may still be capturing: stopped first, bounded, as a salvage does (L review
            // 128) — never `captureEnded` while it may still write. One that will not stop is held.
            if sentinel.stopping {
                let helperStop = await boundedHelperStop("stop before waiting for the folder", session: sentinel.sessionKey)
                guard stillOwnsTheSession(sentinel) else { return .handled }
                if !helperStop.letGo {
                    holdForHelper(sentinel, because: helperStop.because)
                    return .heldForHelper
                }
            }
            // Never deleted: the recording data may be on the missing drive (§8.9). No capture: disarmed.
            relaunchProbing = false
            endCaptureIfStillOwned()
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
            useFolderReadsForTheTranscript()   // the pipeline's session.json writes: this reader, its bound (L review 234)
            try transcriptionRunner.setupChunkedPipeline(
                captureClient: captureClient, outputDirectory: outputDir, sessionBaseName: stripSegmentSuffix(sentinel.systemAudioPath),
                config: configManager.config, seededState: seed, ownStateOnDisk: scan.persisted, firstChunkIndex: scan.liveIndex)
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
        let loaded = pendingLoad()
        // Each in its own row, never "Recording STOPPED" (L review 249).
        if let aside = loaded.setAside {
            reportPendingListNote("Parley could not read its list of unfinished recordings — it was set aside in \(abbreviatedDisplayPath(aside.deletingLastPathComponent().path)), and those recordings may need to be transcribed by hand.")
        } else if let kept = loaded.keptUnreadable {
            // Not "set aside": it could not even be moved. Left in place, never overwritten (L review 130); the recordings
            // Parley keeps since go to a new list beside it, so every hold is tracked (L review 166).
            reportPendingListNote("Parley could not read its list of unfinished recordings, nor move it aside — it is left in \(abbreviatedDisplayPath(kept.deletingLastPathComponent().path)), and those recordings may need to be transcribed by hand. Recordings Parley keeps since go to a separate list beside it.")
        }
        // A list kept beside it that cannot be read is said too — never only a log line (L review 196).
        for list in loaded.unreadableOverflow {
            reportPendingListNote("Parley could not read a list of unfinished recordings (\(list.lastPathComponent)) — it is left as it is in \(abbreviatedDisplayPath(list.deletingLastPathComponent().path)), and those recordings may need to be transcribed by hand.")
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
    /// True when it was written — to the pending list, or, that failing, to the slot.
    @discardableResult
    private func keepPending(_ sentinel: RecordingSentinel, markStopping: Bool = false, cause: RecordingSentinel.StopCause? = nil,
                             held: RecordingSentinel.HeldReason? = nil, heldBecause: String? = nil,
                             keptWhileWriting: RecordingSentinel.KeptWhileWriting? = nil) -> Bool {
        let slot = slotRead()
        let slotIsThisSession = slot?.sessionKey == sentinel.sessionKey
        var kept = (slotIsThisSession ? slot : nil) ?? sentinel
        kept.stopCause = kept.stopCause ?? sentinel.stopCause ?? cause ?? Self.relaunchCause(sentinel)
        kept.heldReason = kept.heldReason ?? sentinel.heldReason ?? held
        kept.heldBecause = kept.heldBecause ?? sentinel.heldBecause ?? heldBecause   // the first hold's, as its reason (L review 247)
        kept.stopping = kept.stopping || sentinel.stopping || markStopping
        kept.salvageBegan = kept.salvageBegan || sentinel.salvageBegan
        // Why it was kept, apart from why it stopped (L review 228): the latest salvage's, whose write may still land.
        kept.keptWhileWriting = keptWhileWriting ?? sentinel.keptWhileWriting ?? kept.keptWhileWriting
        // A quit's own mark wins over `willPowerOff`'s time-boxed one (L review 174).
        let quit = kept.quitDuringFinalize || sentinel.quitDuringFinalize
        let onlyPowerOff = (!kept.quitDuringFinalize || kept.quitMarkedByPowerOff) && (!sentinel.quitDuringFinalize || sentinel.quitMarkedByPowerOff)
        kept.quitDuringFinalize = quit
        kept.quitMarkedByPowerOff = quit && onlyPowerOff
        var pending = pendingSessions().filter { $0.sessionKey != sentinel.sessionKey }
        pending.append(kept)
        do {
            try pendingWrite(pending)
        } catch {
            // Not written: the slot keeps it instead (marked), so the next launch still finds it.
            Logger.state.error("Could not keep the session for later: \(error, privacy: .private)")
            return (try? slotWrite(kept)) != nil
        }
        if slotIsThisSession {
            slotDelete()
        }
        return true
    }

    private func removePending(_ sentinel: RecordingSentinel) {
        let pending = pendingSessions().filter { $0.sessionKey != sentinel.sessionKey }
        do {
            try pendingWrite(pending)
        } catch {
            Logger.state.error("Could not update the pending sessions: \(error, privacy: .private)")
        }
    }

    /// The helper did not stop a recording (L follow-up 40; L review 81): its file may still be written, so it
    /// is not salvaged now. Held — marked `stopping` (salvage-only: never resumed) and pending (out of the slot a
    /// next Start writes), the helper's mic kept marked (#192, L review 88) — the user told (a sticky row), and
    /// finished at the next event once the helper's stop says it let go (L review 84). `reason`: why it is held, carried on
    /// the pending entry (L review 177) — the relaunch's by default.
    /// `because`: why the helper held on, in words (L review 247) — kept on the pending entry, so the session's record says it
    /// when it is finished, whatever evidence was reset in between.
    /// True once the hold is WRITTEN: the stop attempt then ends (L review 269) — the Quit reads the hold from disk.
    @discardableResult
    private func holdForHelper(_ sentinel: RecordingSentinel,
                               message: String = "Parley couldn’t stop the previous recording cleanly — its audio is kept, and Parley will finish it once the capture helper lets go.",
                               cause: RecordingSentinel.StopCause? = nil, reason: RecordingSentinel.HeldReason = .relaunch,
                               because: String? = nil) -> Bool {
        // The caller's own capture (L reviews 242, 264), which no Start can own yet: a failed start's (its start still runs,
        // and refuses another), a Stop's (the recording's phase), a failed restart's (nothing awaited since its phase went
        // idle), a failed resume's (its relaunch still probing), or a relaunch's (through `stillOwnsTheSession` right before).
        captureClient.captureEnded()
        setHelperMic(sentinel.micDeviceUID)
        let written = keepPending(sentinel, markStopping: true, cause: cause, held: reason, heldBecause: because)
        if written { stopAttemptEnded(sentinel.sessionKey) }
        reportStopped(message, recovered: false, session: sentinel.sessionKey)
        // Held during a confirmed Quit (L review 223): the Quit says so, and keeps the LaunchAgent for the next launch.
        if isQuitting { quitLeftAHeldSession = true }
        return written
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
    /// `keptWhileWriting`: a salvage's transcript write did not answer (L review 228) — kept with what it knew, so the write
    /// that lands later is said.
    private func waitForUnansweringFolder(_ sentinel: RecordingSentinel,
                                          keptWhileWriting: RecordingSentinel.KeptWhileWriting? = nil) async {
        foldersNotAnswering.insert(sentinel.sessionKey)
        guard stillOwnsTheSession(sentinel, keptWhileWriting: keptWhileWriting) else { return }
        endCaptureIfStillOwned()
        keepPending(sentinel, keptWhileWriting: keptWhileWriting)
        await updateFolderAlarm()
    }

    /// Why a pending session's folder is not ready (L reviews 79, 210).
    private enum FolderWait: Equatable { case notWritable, unreachable, notAnswering }

    private func applyFolderAlarm(pending: [RecordingSentinel], folders: PendingFolders) {
        foldersNotAnswering.formIntersection(pending.map(\.sessionKey))   // a session no longer pending is resolved
        // Every pending folder has an answer or a timeout of its read's OWN bound — a joined read waited within it (L review
        // 210): no early return while another folder is busy (L review 216). A timeout is "not answering", said as such.
        let folderOf = { (s: RecordingSentinel) in URL(fileURLWithPath: s.systemAudioPath).deletingLastPathComponent().path }
        let waiting: [(folder: String, wait: FolderWait)] = pending.compactMap {
            if foldersNotAnswering.contains($0.sessionKey) || folders.notAnswering.contains(folderOf($0)) { return (folderOf($0), .notAnswering) }
            switch folders.statuses[folderOf($0)] ?? .unreachable {
            case .reachable: return nil
            case .notWritable: return (folderOf($0), .notWritable)
            case .unreachable: return (folderOf($0), .unreachable)
            }
        }
        if waiting.isEmpty {
            appState.clearAppAlarm(.recordingFolderUnavailable)
        } else {
            appState.raiseAppAlarm(.recordingFolderUnavailable, message: Self.folderAlarmMessage(waiting))
        }
    }

    /// What the folder alarm says (L reviews 79, 210, 241): one state for every waiting folder is said as that state; folders in
    /// different states are each said as their own — never one word for all.
    private static func folderAlarmMessage(_ waiting: [(folder: String, wait: FolderWait)]) -> String {
        let states = Set(waiting.map(\.wait))
        if states == [.notWritable] {
            // There, but read-only: a permissions problem, not a missing drive (L review 79).
            return "Parley can’t write to the recording folder — check its permissions. The recording data is kept, and Parley will retry."
        }
        if states == [.notAnswering] {
            // No answer within its bound: not answering — never "not reachable" (L review 210).
            return "The recording folder isn’t answering — Parley will keep the recording data and retry."
        }
        if states == [.unreachable] {
            return "The recording folder isn’t reachable — Parley will keep the recording data and retry."
        }
        var seen = Set<String>(), each: [String] = []
        for (folder, wait) in waiting where seen.insert(folder).inserted {
            let state: String
            switch wait {
            case .notWritable: state = "can’t be written to — check its permissions"
            case .unreachable: state = "isn’t reachable"
            case .notAnswering: state = "isn’t answering"
            }
            each.append("\(abbreviatedDisplayPath(folder)) \(state)")
        }
        return "Some recording folders aren’t ready: " + each.joined(separator: "; ") + ". Parley will keep the recording data and retry."
    }

    /// Finish every pending session whose folder is back and whose capture the helper has let go of
    /// (L follow-ups 24, 35, 40). Event-driven, never a timer: at launch, when a volume mounts, when the
    /// Mac wakes, and when a recording ends. Only while idle with no start in flight — the sentinel slot
    /// and the helper are a recording's own then; asked for while busy, it runs at the next idle.
    public func retryPendingSessions() async {
        noteRecordingRoot()
        guard !pendingSessions().isEmpty else {
            appState.clearAppAlarm(.recordingFolderUnavailable)
            return
        }
        guard appState.isIdle, !isStartInFlight, !recoveryGateHeld else {
            retryPendingWhenIdle = true
            return
        }
        recoveryGateHeld = true
        stoppedBatch = ([], [], [], [], [])
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
        // Nor one whose chunks are still being processed in this process (#226): it is retried once they end.
        let ready = pending.filter {
            $0.sessionKey != heldKey && !(helperHoldsOn && $0.heldReason != nil) && !chunksStillProcessing.contains($0.sessionKey)
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
                let letGo = await boundedHelperStop("stop a pending session", session: nil).letGo   // its sessions are held on disk
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
    /// The bound on the rebuild's composite look — its sweeps, the damaged record moved aside, the session's state and its
    /// orphans read (L review 215): longer than one read, so a slow but healthy share is never called "not answering".
    /// Tests shorten it.
    var folderPrepareDeadline: Duration = .seconds(15)
    /// What the folder reads ask the file system. Tests inject a slow or fake one.
    var folderProbe: FolderProbe = .live
    /// Where the recovery file and the pending list are read and written: one serial queue — off the main actor on the hot
    /// paths (L review 217). Tests inject one that hangs.
    var sentinelIO = SentinelIO()
    /// The bound on the recovery file's I/O off the main actor (Application Support: a local folder, normally instant).
    /// Tests shorten it.
    var sentinelDeadline: Duration = .seconds(5)
    /// Where every blocking recording-folder read runs: a serial queue per volume, never the cooperative pool (L
    /// reviews 123, 160). Tests inject one that hangs.
    var folderReads: FolderReads = .shared

    /// The recording root, as the settings name it now, is the one folder the reader resolves (L review 237): the day folders
    /// under it are derived from it lexically.
    private func noteRecordingRoot() {
        folderReads.noteRecordingRoot(configManager.config.recordingDirectory)
    }

    /// A read of `folder`, off the main actor and bounded (on awake time): nil when it did not answer — or when the
    /// folder still has an earlier read outstanding (L reviews 123, 160: `FolderReads`, its volume's queue, never the pool).
    private func readOffMain<T>(_ label: String, folder: URL, bound: Duration? = nil, _ read: @escaping @Sendable () -> T) async -> T? {
        await folderReads.read(label, folder: folder.path, seconds: Self.seconds(bound ?? folderReadDeadline), read)
    }

    /// What the pending sessions' folders answered, by folder path (L reviews 75, 164, 210). A folder whose read did not
    /// answer within its own bound — joining an earlier read of it included — is in `notAnswering`, never given a status.
    struct PendingFolders {
        var statuses: [String: FolderStatus] = [:]
        var notAnswering: Set<String> = []
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
                case .timedOut: result.notAnswering.insert(path)
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
            endCaptureIfStillOwned()
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
            newSentinel.heldBecause = nil
            newSentinel.salvageBegan = false
            try slotWrite(newSentinel)
            currentSessionKey = newSentinel.sessionKey   // L review 266
            // The rotator is anchored at the current time inside: the monotonic clock behind it cannot be
            // persisted, so a resume re-anchors at resume time, never at the seeded `meetingStart` (C10).
            // `firstChunkIndex` is the plan's: the rotator must name the file the helper is writing.
            useFolderReadsForTheTranscript()   // the pipeline's session.json writes: this reader, its bound (L review 234)
            try transcriptionRunner.setupChunkedPipeline(
                captureClient: captureClient, outputDirectory: outputDir, sessionBaseName: sessionId,
                config: config, seededState: seed, ownStateOnDisk: scan.persisted, firstChunkIndex: plan.index
            )
        } catch {
            Logger.state.error("Resume after a crash failed: \(error, privacy: .private)")
            transcriptionRunner.teardownChunkedPipeline()
            resetRecoveryConfirmation()
            crashBeforeRecording = false
            // Never a capturing helper behind an idle app — a start that timed out may still commit (L9 review
            // 44); its sealed file joins the salvage below. A helper that will not stop keeps the session: a file
            // still being written is never salvaged (27, 40).
            let helperStop = await stopAfterFailedStart(captureStarted: captureStarted, startIssued: startIssued, error: error,
                                                        label: "stop after failed resume", session: sentinel.sessionKey)
            if !helperStop.letGo {
                holdForHelper(sentinel, because: helperStop.because)
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
        onRecordingStarted?()
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

    // MARK: - The recovery file's I/O (L review 217)

    /// The recovery file's slot, as it stands, on the recovery file's queue (in order with its queued writes).
    func slotRead(_ label: String = "read") -> RecordingSentinel? {
        let directory = sentinelDirectory
        return sentinelIO.sync(label) { RecordingSentinel.read(directory: directory) }
    }

    func slotWrite(_ sentinel: RecordingSentinel, _ label: String = "write") throws {
        let directory = sentinelDirectory
        try sentinelIO.sync(label) { try RecordingSentinel.write(sentinel, directory: directory) }
    }

    func slotDelete(_ label: String = "delete") {
        let directory = sentinelDirectory
        sentinelIO.sync(label) { RecordingSentinel.delete(directory: directory) }
    }

    /// The pending list, on the recovery file's queue.
    func pendingLoad() -> (sessions: [RecordingSentinel], setAside: URL?, keptUnreadable: URL?, unreadableOverflow: [URL]) {
        let directory = sentinelDirectory
        return sentinelIO.sync("pending: read") { RecordingSentinel.loadPending(directory: directory) }
    }

    func pendingWrite(_ sessions: [RecordingSentinel]) throws {
        let directory = sentinelDirectory
        try sentinelIO.sync("pending: write") { try RecordingSentinel.writePending(sessions, directory: directory) }
    }

    /// The slot, read off the main actor, bounded (L review 217): nil when it is not there — or did not answer (logged).
    func slotReadOffMain(_ label: String) async -> RecordingSentinel? {
        let directory = sentinelDirectory
        guard let read = await sentinelIO.run(label, seconds: Self.seconds(sentinelDeadline), { RecordingSentinel.read(directory: directory) }) else {
            Logger.state.error("The recovery file did not answer (\(label, privacy: .public))")
            return nil
        }
        return read
    }

    /// `sentinel` written off the main actor, bounded (L review 217): a write that does not answer throws — never claimed.
    func slotWriteOffMain(_ sentinel: RecordingSentinel, _ label: String, seconds: Double? = nil) async throws {
        let directory = sentinelDirectory
        guard let written = await sentinelIO.run(label, seconds: seconds ?? Self.seconds(sentinelDeadline), {
            Result { try RecordingSentinel.write(sentinel, directory: directory) }
        }) else {
            Logger.state.error("The recovery file's write did not answer (\(label, privacy: .public))")
            throw RecoveryFileNotAnswering()
        }
        try written.get()
    }

    /// The slot deleted off the main actor, bounded (L review 217). One that does not answer stays queued, in order: false.
    @discardableResult
    func slotDeleteOffMain(_ label: String) async -> Bool {
        let directory = sentinelDirectory
        guard await sentinelIO.run(label, seconds: Self.seconds(sentinelDeadline), { RecordingSentinel.delete(directory: directory) }) != nil else {
            Logger.state.error("The recovery file's delete did not answer (\(label, privacy: .public)) — it stays queued")
            return false
        }
        return true
    }

    /// Returns once everything queued on the recovery file's queue has run. Internal for tests.
    func settleSentinelIOForTesting() async {
        _ = await sentinelIO.run("settle", seconds: 5) { () }
    }

    /// Returns once everything queued on the stop request's queue has run. Internal for tests.
    func settleStopRequestIOForTesting() async {
        _ = await stopRequestIO.run("settle", seconds: 5) { () }
    }

    /// The stopping mark, off the main actor, bounded (L reviews 217, 235) — never past an exit's own `deadline`. One that
    /// does not answer stays queued, and the stop is KEPT APART (L review 236): a crash before the mark lands never lets the
    /// next launch resume a recording the user stopped. `session`: the recording's key, when the caller knows it — else the
    /// live pipeline's.
    func markSentinelStoppingOffMain(by deadline: SuspendingClock.Instant? = nil, session: String? = nil) async {
        let directory = sentinelDirectory
        guard !(await exitMark("mark stopping", by: deadline, { Self.markStopping(directory: directory) })) else { return }
        await keepStopApart(session: session ?? transcriptionRunner.chunkRotator.map { Self.sessionKey(of: $0.sessionLocation) } ?? currentSessionKey,
                            by: deadline)
    }

    /// A session's key, as `RecordingSentinel.sessionKey` spells it: its folder and its id.
    nonisolated static func sessionKey(of location: (outputDir: URL, sessionId: String)) -> String {
        location.outputDir.appendingPathComponent(location.sessionId).path
    }

    /// The stopping mark did not answer (L review 236): the Stop is kept apart — in a file of its own written on a queue of
    /// its own, bounded as the mark was — so the next launch treats that recording as stopping. Once per session: remembered
    /// only once the file is written (L review 265), so a write that failed — or has not answered — is made again at the
    /// next mark. With no known session nothing can be kept (logged).
    private func keepStopApart(session: String?, by deadline: SuspendingClock.Instant?) async {
        guard let session else {
            Logger.state.error("A stopping mark did not answer, and no recording is known to keep the stop apart for")
            return
        }
        guard stopKeptApart?.sessionKey != session else { return }
        let request = RecordingSentinel.StopRequest(sessionKey: session, requestedAt: Date())
        let directory = sentinelDirectory
        let bound = deadline.map { min(exitMarkBound, max(.zero, $0 - .now)) } ?? sentinelDeadline
        switch await stopRequestIO.run("stop request: write", seconds: max(0.001, Self.seconds(bound)), {
            Result { try RecordingSentinel.writeStopRequest(request, directory: directory) }
        }) {
        case .success?:
            stopKeptApart = request
            Logger.state.error("The recovery file's stopping mark did not answer — the stop is kept apart, so it is never resumed")
        case .failure(let error)?:
            Logger.state.error("The stopping mark did not answer, and the stop could not be kept apart — tried again at the next mark: \(error, privacy: .private)")
        case nil:
            Logger.state.error("The stopping mark did not answer, and keeping the stop apart did not answer either — it stays queued")
        }
    }

    /// A Stop deferred during a crash restart (L review 266): its mark is only queued, never waited for — so the stop is kept
    /// apart too, queued on its own queue, never awaited (nothing may suspend before the phase says the Stop). Its end — the
    /// recovery file deleted, or its salvage — drops it, queued after this write.
    private func keepStopApartQueued(session: String?) {
        guard let session else {
            Logger.state.error("A Stop deferred during a crash restart knows no recording to keep the stop apart for")
            return
        }
        let request = RecordingSentinel.StopRequest(sessionKey: session, requestedAt: Date()), directory = sentinelDirectory
        stopRequestIO.enqueue("stop request: write") {
            do {
                try RecordingSentinel.writeStopRequest(request, directory: directory)
            } catch {
                Logger.state.error("A Stop deferred during a crash restart could not be kept apart: \(error, privacy: .private)")
            }
        }
    }

    /// A relaunch's recovery file is not the one a Stop kept apart names — or there is none (L review 267): that stop's
    /// recording was settled another way, and its stale file goes. Queued on its own queue, before the relaunch reads it.
    private func clearStaleStopRequest(keeping slotKey: String?) {
        let directory = sentinelDirectory
        stopRequestIO.enqueue("stop request: clear stale") {
            guard let request = RecordingSentinel.readStopRequest(directory: directory), request.sessionKey != slotKey else { return }
            RecordingSentinel.deleteStopRequest(directory: directory)
            Logger.state.info("A stop kept apart for a recording no recovery file names — cleared")
        }
    }

    /// When a Stop of `sentinel`'s recording was kept apart, if one was (L review 236): read on its own queue, bounded — one
    /// that does not answer is none.
    private func stopRequestedAt(for sentinel: RecordingSentinel) async -> Date? {
        let directory = sentinelDirectory
        guard let request = await stopRequestIO.run("stop request: read", seconds: Self.seconds(sentinelDeadline), {
            RecordingSentinel.readStopRequest(directory: directory)
        }) ?? nil, request.sessionKey == sentinel.sessionKey else { return nil }
        return request.requestedAt
    }

    /// The recording's fate is settled — its recovery file gone, or its salvage run: the stop kept apart for it goes too (L
    /// review 236). Queued on its own queue; one that names another recording is left.
    private func dropStopKeptApart(for session: String) {
        if stopKeptApart?.sessionKey == session { stopKeptApart = nil }
        let directory = sentinelDirectory
        stopRequestIO.enqueue("stop request: delete") {
            guard RecordingSentinel.readStopRequest(directory: directory)?.sessionKey == session else { return }
            RecordingSentinel.deleteStopRequest(directory: directory)
        }
    }

    // MARK: - Sentinel liveness (§8.3, §8.8)

    /// Stamp the sentinel's `lastAliveAt`: the alive timer, every rotation, a re-attach. Never creates
    /// one — no sentinel, no recording to vouch for.
    func refreshSentinelLiveness(now: Date = Date()) {
        // While a crash recovery runs the helper is dead: nothing is being captured to vouch for (L
        // follow-up 37). A successful restart stamps it again.
        guard !recoveryInFlight else { return }
        // Queued, never waited for (L review 217): every rotation and the alive timer write it, and a slow Application Support
        // folder never holds the main actor. Read and written in one step on the recovery file's queue, in order with the rest.
        let directory = sentinelDirectory
        sentinelIO.enqueue("liveness") {
            guard var sentinel = RecordingSentinel.read(directory: directory) else { return }
            sentinel.lastAliveAt = now
            do {
                try RecordingSentinel.write(sentinel, directory: directory)
            } catch {
                Logger.state.error("Could not refresh the recovery file's liveness: \(error, privacy: .private)")
            }
        }
    }

    /// The mark itself, read and written in one step on the recovery file's queue.
    nonisolated static func markStopping(directory: URL?) {
        guard var sentinel = RecordingSentinel.read(directory: directory), !sentinel.stopping else { return }
        sentinel.stopping = true
        do {
            try RecordingSentinel.write(sentinel, directory: directory)
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
    /// said in a row naming their files — kept there if they are, not transcribed. Its own row, "Possible audio after a
    /// transcript" (L reviews 219, 241, 268): only what is certain — nothing stopped, and it never takes the Stop's own
    /// "Recording STOPPED" row.
    private func lateChunksUnchecked(_ indices: [Int]) {
        captureClient.record(.folderNotAnswering, .anomaly, ["during": "stop", "unchecked_chunks": indices.map(String.init).joined(separator: ",")])
        guard let location = transcriptionRunner.chunkRotator?.sessionLocation else { return }
        let files = indices.map { "\(location.sessionId)-\($0).wav" }
        let message = RecoveryMessages.lateChunksUnchecked(files: files, folder: abbreviatedDisplayPath(location.outputDir.path))
        presentAlarms(reshow: raiseSessionRow(.possibleAudioAfterTranscript, message: message))
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
    /// review 167). `helperJustLetGo`: the helper let go of THIS session just now — a relaunch stopped its capture (a
    /// re-attach that found it transcribed, a recording that was stopping) — so what it holds is this session's, even for a
    /// session found already transcribed (L review 248).
    func salvageAtLaunch(sentinel: RecordingSentinel, outputDir: URL, drainHelper: Bool = true, helperJustLetGo: Bool = false) async {
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
            // (R2's `cleanupFinalized`, L review 94) and that is all: no second finalize — and no rename panel and no row,
            // unless the user is owed one (below: a write that landed late, audio recorded after the transcript).
            Logger.state.info("The recovery file of an already transcribed recording lingered — its leftovers are cleaned up, nothing is transcribed again")
            // Its transcript verified: the commit a crash cut short happens now — its live log and coverage go (L review
            // 144) — but only once its record is BUILT (L review 200): the crashed process may never have written it, and
            // the live log may be its only copy. Built without draining: the helper's events are not this session's to take —
            // unless the helper let go of THIS session just now (L review 248): then they are. A record that cannot be written
            // keeps the live log (the commit's unwritten guard).
            let drainNow = drainHelper && helperJustLetGo
            await captureClient.adoptSession(sessionId: sessionId, directory: outputDir, drainHelper: drainNow)
            recordWhyHeld(sentinel)
            _ = await captureClient.finalizeSessionDiagnostics(sessionId: sessionId, engine: configManager.config.engine.rawValue,
                                                               recordingDirectory: outputDir, drainHelper: drainNow)
            captureClient.commitSessionDiagnostics(sessionId: sessionId, directory: outputDir)
            forgetSession(sentinel)
            // After the adopt's and the build's awaits (L review 242): a Start that got in during them keeps its crash detection.
            endCaptureIfStillOwned()
            // Kept while its salvage's transcript write did not answer — the write landed later (L review 228): said as that
            // salvage's own row, a transcript written, and the rename panel offered — never silence.
            if let kept = sentinel.keptWhileWriting {
                let transcript = outputDir.appendingPathComponent("\(sessionId).json")
                let failures = await readOffMain("salvage: transcript", folder: outputDir) {
                    SalvageOutcome.recognitionFailures(inTranscriptAt: transcript)
                } ?? nil
                let outcome = SalvageOutcome(kind: .transcriptWritten(transcript), chunkCount: kept.chunkCount,
                                             recognitionFailures: failures ?? .init(), recognitionChecked: failures != nil)
                // The rename panel opens only over a session still ours — never over a Start that got in meanwhile.
                if appState.isIdle, !userStartInFlight { appState.phase = .transcribing(progress: "Recovering…") }
                await presentCompletedTranscription(TranscriptionResult(jsonPath: transcript))
                reportStopped(salvageMessage(sentinel, stoppedAt: kept.stoppedAt, outcome: outcome, scan: nil, outputDir: outputDir),
                              recovered: true, session: sentinel.sessionKey)
            // Kept because its folder stopped answering — its transcript's write landed once it answered (L review 185):
            // the user was told it would be finished, so it is said that it was, never silence.
            } else if sentinel.stopCause == .folderNotAnswering {
                reportStopped(RecoveryMessages.finishedOnceTheFolderAnswered(transcript: "\(sessionId).json"), recovered: true,
                              session: sentinel.sessionKey)
            }
            // Audio written AFTER the transcript, which it does not list, is never silent (L review 137): the scan
            // noted it in the record; the row says how much, beside which transcript, and where it is kept (L review 181).
            if let late = scan.lateAudio {
                reportAudioAfterTranscript(RecoveryMessages.audioAfterTranscript(seconds: late.seconds, transcript: late.transcript,
                                                                                 folder: abbreviatedDisplayPath(outputDir.path)),
                                           session: sentinel.sessionKey)
            }
            return
        }
        let stoppedAt = scan.stoppedAt, chunkCount = scan.chunkCount
        let config = configManager.config
        // The engine, before anything is bound, drained or written (L review 178). One that is not there — it cannot be
        // made on this macOS, or its speech or diarization model is not downloaded (or installed) while there is audio to
        // recognise (L reviews 229, 232) — is not the audio's failure: the session stays pending, said so with what makes the
        // engine ready (L review 230), and is finished once it is. A session whose every chunk is already transcribed needs
        // no engine.
        let transcriber: any TranscriptionEngine, diarizer: (any DiarizationProvider)?
        do {
            (transcriber, diarizer) = try await enginesForSalvage(config: config, toRecognise: scan.orphanCount)
        } catch {
            Logger.state.error("The transcription engine is not ready — the session waits for it: \(error, privacy: .private)")
            // A Start during the engine check owns the app now: the session waits all the same, and nothing touches that start.
            guard stillOwnsTheSession(sentinel) else { return }
            waitForTheEngine(sentinel, stoppedAt: stoppedAt, why: error.localizedDescription,
                             remedy: Self.engineRemedy(for: error, engine: config.engine))
            endCaptureIfStillOwned()
            return
        }
        guard stillOwnsTheSession(sentinel) else { return }
        // No longer waiting for its engine: what the row said is replaced by what the salvage wrote (L review 272).
        let saidWaiting = saidWaitingForEngine.removeValue(forKey: sentinel.sessionKey)?.message
        appState.phase = .transcribing(progress: "Recovering…")
        let outcome: SalvageOutcome
        var recovered: TranscriptionResult?
        do {
            // Bound to this session BEFORE its drain (L review 98): reset, drain, build — as the resume does. What
            // the helper still holds is this session's (a pending retry attributed a stray helper's already) — unless
            // it holds a held session's capture: then nothing is drained (L review 167).
            await captureClient.adoptSession(sessionId: sessionId, directory: outputDir, drainHelper: drainHelper)
            recordWhyHeld(sentinel)
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
        } catch let error as FolderNotAnswering {
            // The folder stopped answering mid-salvage (L review 158): nothing was CONFIRMED written — but a write that did
            // not answer may still land (L review 185). The session waits: kept, its folder said not to answer, never
            // salvaged as failed — and, when it was the transcript's write, kept WHILE WRITING (L review 228), with what this
            // salvage knew: the pass whose finalized gate finds the transcript then says it as this salvage's row.
            Logger.state.error("The salvage's folder did not answer — the session waits")
            if case .transcribing = appState.phase { appState.phase = .idle }
            await waitForUnansweringFolder(sentinel, keptWhileWriting: error.duringWrite
                ? RecordingSentinel.KeptWhileWriting(stoppedAt: stoppedAt, chunkCount: chunkCount) : nil)
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
        let message = salvageMessage(sentinel, stoppedAt: stoppedAt, outcome: outcome, scan: scan, outputDir: outputDir)
        // Only a written transcript is a recovery (L review 133): nothing to salvage, or chunks kept untranscribed,
        // are said on their own — never counted in "N earlier recordings were recovered".
        if case .transcriptWritten = outcome.kind {
            reportStopped(message, recovered: true, session: sentinel.sessionKey, replacing: saidWaiting)
        } else {
            reportStopped(message, recovered: false, session: sentinel.sessionKey, replacing: saidWaiting)
        }
        endCaptureIfStillOwned()   // after the salvage's awaits (L review 242)
    }

    /// A salvage's row (§7.4 P6): why it stopped and what was written. A quit while recovering or finishing it, a hold, an
    /// older-format recording, or a relaunch's cause — as the launch that first kept it saw it (L reviews 69, 147, 177, 194).
    private func salvageMessage(_ sentinel: RecordingSentinel, stoppedAt: Date, outcome: SalvageOutcome, scan: SalvageScan?,
                                outputDir: URL) -> String {
        if sentinel.quitDuringFinalize, sentinel.salvageBegan {
            // Quit while an earlier launch recovered it (L review 194): the cause that salvage first saw, then the quit.
            return RecoveryMessages.quitWhileRecovering(at: stoppedAt, outcome: outcome, cause: sentinel.stopCause ?? Self.relaunchCause(sentinel))
        } else if sentinel.quitDuringFinalize {
            return RecoveryMessages.quitWhileFinishing(outcome: outcome)   // a quit, not a crash (L follow-up 42)
        } else if let held = sentinel.heldReason {
            // Held for the helper (L review 177): what happened, then that Parley kept it until the helper let go — never
            // "Parley crashed" for a capture that failed while Parley ran.
            return RecoveryMessages.heldStopped(at: stoppedAt, outcome: outcome, held: held,
                                                cause: sentinel.stopCause ?? Self.relaunchCause(sentinel))
        } else if outcome.kind == .nothingToSalvage, let scan, scan.legacyAudio {
            return RecoveryMessages.relaunchStoppedKeepingOlderFormat(at: scan.legacyLastWrite.map { min($0, Date()) },
                                                                      folder: abbreviatedDisplayPath(outputDir.path))
        }
        // Why it stopped: as the launch that first kept it saw it — never the boot it is salvaged in (L reviews 69, 147).
        return RecoveryMessages.relaunchStopped(at: stoppedAt, outcome: outcome, cause: sentinel.stopCause ?? Self.relaunchCause(sentinel))
    }

    /// A held session's record says why it was held (L review 247): the stop failure recorded when it was held went into
    /// whatever evidence was bound then, which a later adopt reset. Recorded again, into this session's own — just bound.
    /// Once per session (L review 268): a salvage attempt that did not finish already recorded it into the session's live log.
    private func recordWhyHeld(_ sentinel: RecordingSentinel) {
        guard let held = sentinel.heldReason, recordedWhyHeld.insert(sentinel.sessionKey).inserted else { return }
        var detail = ["source": "app", "held": held.rawValue]
        if let because = sentinel.heldBecause { detail["held_because"] = because }
        captureClient.record(.streamStopError, .anomaly, detail)
    }

    /// The slot's session is being salvaged (L review 194): the slot is stamped with the cause this launch first sees — first
    /// keeping wins, as the pending list's — and that a salvage began. A Quit during the salvage then leaves both beside its
    /// mark, so the next launch says the recording stopped for that cause and Parley was quit while recovering it — never
    /// only "quit". A slot already marked quit keeps what it says: that quit came during the user's own Stop.
    private func markSalvageBegan(_ sentinel: RecordingSentinel) {
        guard var slot = slotRead(), slot.sessionKey == sentinel.sessionKey,
              !slot.salvageBegan, !slot.quitDuringFinalize else { return }
        slot.stopCause = slot.stopCause ?? sentinel.stopCause ?? Self.relaunchCause(slot)
        slot.salvageBegan = true
        do {
            try slotWrite(slot)
        } catch {
            Logger.state.error("Could not mark the salvage on the recovery file: \(error, privacy: .private)")
        }
    }

    /// The live pipeline of a session that is NOT finalized now (L review 137): the chunks already queued are
    /// processed — each persisted to session.json — then the rotation stops and the pipeline goes. A later salvage
    /// finishes the session from there.
    /// Waited for within a bound (#226): chunks that do not finish go on behind the session — still persisted when they
    /// do — and it is not salvaged until then (`chunksStillProcessing`).
    private func settleAbandonedPipeline() async {
        transcriptionRunner.stopChunkRotation()
        if let processor = transcriptionRunner.chunkProcessor {
            let session = transcriptionRunner.chunkRotator.map { Self.sessionKey(of: $0.sessionLocation) }
            _ = await chunksProcessed(by: processor, session: session, during: "settling an abandoned pipeline")
        }
        transcriptionRunner.teardownChunkedPipeline()
    }

    /// The least a Stop or a salvage waits for the chunks still being processed (#226): a cold engine's model load is in
    /// it, whatever the audio's length.
    nonisolated static let chunkProcessingFloor: Duration = .seconds(300)

    /// How long the chunks still being processed are waited for (#226): as long as the audio they hold — from when the
    /// oldest of them began recording until now — and never under the floor. A pipeline slower than real time could not
    /// keep up with a meeting at all, so a healthy one, however slow the Mac, ends well inside it (measured: about 60× real
    /// time per stream on an M5 Pro); only chunks that will not finish reach it. A wall-clock span, never a file's size:
    /// the folder may be what does not answer.
    nonisolated static func chunkProcessingBound(oldestUnfinishedStart: Date?, now: Date = Date()) -> Duration {
        let audio = oldestUnfinishedStart.map { now.timeIntervalSince($0) } ?? 0
        return max(chunkProcessingFloor, .milliseconds(Int64(max(0, audio) * 1000)))
    }

    /// Tests: the bound itself, in place of `chunkProcessingBound`.
    var chunkProcessingDeadline: Duration?

    /// Sessions whose chunks a Stop or a salvage stopped waiting for (#226), by session key: their tasks still run —
    /// hung on a folder that does not answer, or only slow — and still persist each chunk when they end. Until then the
    /// session is never salvaged in this process: a second pipeline over the same files would transcribe the chunk twice
    /// and write its archive under the first. A relaunch has no such tasks, and salvages it as it stands.
    private(set) var chunksStillProcessing: Set<String> = []

    /// Every chunk `processor` holds, processed — `lastChunk` (the Stop's) first — within the bound (#226). False when it
    /// ran out: recorded, and the session marked as still processing; its tasks go on, and a pending retry runs once they
    /// end. The processor's write outcomes are no longer this coordinator's: the next recording's alarm is its own.
    private func chunksProcessed(by processor: ChunkProcessor, session: String?, during step: String,
                                 lastChunk: ChunkRotator.FinalizedChunk? = nil) async -> Bool {
        let oldest = [processor.oldestUnfinishedStart, lastChunk?.startTime].compactMap { $0 }.min()
        let bound = chunkProcessingDeadline ?? Self.chunkProcessingBound(oldestUnfinishedStart: oldest)
        do {
            try await withDeadline(seconds: Self.seconds(bound), label: "chunk processing (\(step))") {
                if let lastChunk { await processor.processLastChunk(lastChunk) }
                await processor.awaitAllProcessed()
            }
            return true
        } catch {
            let unfinished = processor.unfinishedCount
            Logger.state.error("\(unfinished, privacy: .public) chunk(s) were still being processed after \(Self.seconds(bound), privacy: .public) s (\(step, privacy: .public)) — no longer waited for; the session is kept")
            captureClient.record(.folderNotAnswering, .anomaly, ["during": "chunk processing", "step": step, "unfinished_chunks": "\(unfinished)"])
            processor.onSessionWriteFailure = nil
            processor.onSessionWriteSucceeded = nil
            if let session {
                chunksStillProcessing.insert(session)
                Task {
                    await processor.awaitAllProcessed()
                    self.chunksStillProcessing.remove(session)
                    Logger.state.info("The chunks a bounded wait left behind are processed — retrying the pending sessions")
                    // Once idle: the Stop that left them may not have kept its session pending yet.
                    if self.appState.isIdle { await self.retryPendingSessions() } else { self.retryPendingWhenIdle = true }
                }
            }
            return false
        }
    }

    /// A recording ended on a failure path: its recovery file goes — unless its folder did not answer, when nothing
    /// could be checked or salvaged: then it is KEPT, salvage-only, and finished when the folder answers (L review
    /// 122). With no recovery file left, one is made from where the session is: the promise "Parley will finish it when
    /// the folder answers" is only ever made about something kept (L review 163).
    private func finishSentinel(after outcome: SalvageOutcome, sentinel: RecordingSentinel?, location: (outputDir: URL, sessionId: String)? = nil) async {
        guard outcome.kind == .folderNotAnswering else {
            // Settled: the stop kept apart for it goes with its recovery file (L review 267).
            if await slotDeleteOffMain("delete"), let key = sentinel?.sessionKey ?? location.map(Self.sessionKey(of:)) ?? currentSessionKey {
                dropStopKeptApart(for: key)
            }
            return
        }
        if let kept = await slotReadOffMain("read") ?? sentinel ?? location.map({ Self.keptSentinel(for: $0) }) {
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
    private func keepForTheEngine(sentinel: RecordingSentinel?, location: (outputDir: URL, sessionId: String)?, why: String,
                                  remedy: RecoveryMessages.EngineRemedy) {
        guard let kept = slotRead() ?? sentinel ?? location.map({ Self.keptSentinel(for: $0, cause: .userStopped) }) else {
            Logger.state.error("A stopped recording waits for its engine but has no recovery file and no known folder")
            return
        }
        appState.errorMessage = waitForTheEngine(kept, stoppedAt: Date(), markStopping: true, cause: .userStopped, why: why, remedy: remedy)
    }

    /// A session waits for its transcription engine (L reviews 178, 218, 230): kept pending, and said ONCE per run with what
    /// makes the engine ready — the salvage's wait and the Stop's share it (L review 250). Returns the row's message.
    @discardableResult
    private func waitForTheEngine(_ sentinel: RecordingSentinel, stoppedAt: Date, markStopping: Bool = false,
                                  cause: RecordingSentinel.StopCause? = nil, why: String, remedy: RecoveryMessages.EngineRemedy) -> String {
        keepPending(sentinel, markStopping: markStopping, cause: cause)
        let folder = abbreviatedDisplayPath(URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent().path)
        let message = RecoveryMessages.waitingForEngine(at: stoppedAt, folder: folder, why: why, remedy: remedy)
        // Said again when its remedy changed (L review 255) — the stale one replaced in the row, never left beside it.
        let said = saidWaitingForEngine[sentinel.sessionKey]
        if said?.remedy != remedy {
            saidWaitingForEngine[sentinel.sessionKey] = (remedy, message)
            reportStopped(message, recovered: false, session: sentinel.sessionKey, replacing: said?.message)
        }
        return message
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
        if slotRead()?.sessionKey == sentinel.sessionKey {
            slotDelete()
        }
        dropStopKeptApart(for: sentinel.sessionKey)   // L review 236
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
                                                        provenance: provenance, reads: folderReads, seconds: Self.seconds(folderReadDeadline),
                                                        prepareSeconds: Self.seconds(folderPrepareDeadline))
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

    /// The engines a salvage — or a Stop's rebuild — transcribes `toRecognise` chunks with (L reviews 178, 218, 229, 232), as
    /// Setup checks them: the speech engine made and ready, and the diarizer's model there too (VAD is optional: skipped
    /// without its model). Looks only, off the main actor — never a download. Nothing to recognise needs no engine: one
    /// that cannot be made then never keeps a session whose every chunk is transcribed (no asymmetry).
    /// The bound on a salvage's readiness look (L review 254): a speech-model inventory that does not answer within it is
    /// not ready. Tests shorten it.
    var engineReadyDeadline: Duration = .seconds(5)

    private func enginesForSalvage(config: Config, toRecognise: Int) async throws -> (any TranscriptionEngine, (any DiarizationProvider)?) {
        guard toRecognise > 0 else {
            if let prepared = try? prepareEngines(config: config) { return prepared }
            return (NothingToRecognise(), nil)
        }
        let (transcriber, diarizer) = try prepareEngines(config: config)
        // Bounded (L review 254): a look that does not answer — the speech models' inventory — is not ready, never a wait.
        let notReady: String?
        do {
            notReady = try await withDeadline(seconds: Self.seconds(engineReadyDeadline), label: "salvage: engine ready") { () -> String? in
                if !(await transcriber.isReady()) { return await transcriber.notReadyReason() }
                if let diarizer, !(await diarizer.isReady()) { return "its speaker-diarization model is not downloaded" }
                return nil
            }
        } catch {
            Logger.state.error("The transcription engine's readiness did not answer within its bound — not ready yet")
            throw EngineNotReady(why: "its speech model could not be checked in time", checkTimedOut: true)
        }
        if let notReady { throw EngineNotReady(why: notReady) }
        return (transcriber, diarizer)
    }

    /// What makes the engine ready (L review 230): an engine that cannot be made on this macOS — or one Parley's model
    /// download does not make ready — needs another engine chosen in Settings; else Setup or a model download.
    nonisolated static func engineRemedy(for error: Error, engine: EngineID) -> RecoveryMessages.EngineRemedy {
        if case TranscriptionRunner.RunnerError.engineUnavailable = error { return .chooseAnotherEngine }
        if (error as? EngineNotReady)?.checkTimedOut == true { return .checkAgain }   // nothing known yet (L review 270)
        return engine.descriptor.requiresModelDownload ? .setupOrDownload : .chooseAnotherEngine
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

        var orphan: (index: Int, baseName: String, sealed: Bool)?
        if reingestOrphan, let rotator = transcriptionRunner.chunkRotator {
            orphan = await reingestOrphanChunk(rotator: rotator, processor: processor, outputDir: outputDir)
        }

        // Bounded (#226): chunks that do not finish keep the session for when they do — never a salvage that waits.
        guard await chunksProcessed(by: processor, session: Self.sessionKey(of: location), during: "salvage") else {
            transcriptionRunner.teardownChunkedPipeline()
            return SalvageOutcome(kind: .folderNotAnswering, chunkCount: 0)
        }
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
            // In the transcript, but read before its file was known to be sealed (#232): said, never a clean bill.
            if let orphan, !orphan.sealed {
                return SalvageOutcome(kind: outcome.kind, chunkCount: outcome.chunkCount,
                                      recognitionFailures: outcome.recognitionFailures, lastChunkUnchecked: true)
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
        // Each side's verdict too (final review R-I2), in the same folder read: a side unreadable there is the whole
        // transcript unreadable — "couldn't re-read", never a clean bill.
        // And what the echo check recorded (#244): a recording with an echo voice says so, and that
        // headphones avoid it. Unanswered or unreadable reads as no echo — the notice then says it
        // could not check, which covers it.
        let unreadable = CaptureQualityNotice.unreadable
        // What the storage limit removed (#224): the session's chunk passes, and the transcript's own quota pass — waited
        // for alongside the read, with the same bound. A pass that has not run by then is left out of the notice; its
        // deletions are still marked in the transcripts it touched.
        let quotaPass = result.quotaPass, quotaSeconds = Self.seconds(folderReadDeadline)
        async let removedByPass = quotaPass?.removedRecordings(within: quotaSeconds)
        let read = await readOffMain("completion: transcript", folder: jsonPath.deletingLastPathComponent()) {
            (CaptureQualityNotice.anomalyCount(inTranscriptAt: jsonPath),
             CaptureQualityNotice.problemChunkCount(inTranscriptAt: jsonPath),
             CaptureQualityNotice.segmentCount(inTranscriptAt: jsonPath),
             CaptureQualityNotice.sideStatuses(inTranscriptAt: jsonPath),
             EchoNotice.Findings.read(transcriptAt: jsonPath).completionLines)
        }
        let sides = read?.3 ?? nil
        let echoLines = read?.4 ?? 0
        var (anomalies, problemChunks, segments) = (unreadable, unreadable, unreadable)
        if let read, sides != nil { (anomalies, problemChunks, segments) = (read.0, read.1, read.2) }
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
        let passRemoved = await removedByPass
        if quotaPass != nil, passRemoved == nil {
            Logger.files.error("The storage quota pass had not finished when the completion notice was posted — what it removes is marked in the transcripts, not named here")
        }
        let removedRecordings = Set(result.removedRecordings + (passRemoved ?? [])).count
        // The notification is passive, so it always fires: the transcript IS finished, and staying
        // silent about it would be the bigger failure.
        notify(
            CaptureQualityNotice.completionTitle(anomalyCount: anomalies, problemChunkCount: problemChunks, segmentCount: segments,
                                                 remoteStatus: sides?.remote, localStatus: sides?.local, echoLines: echoLines),
            CaptureQualityNotice.completionBody(
                fileName: result.jsonPath.lastPathComponent, anomalyCount: anomalies,
                problemChunkCount: problemChunks, segmentCount: segments,
                remoteStatus: sides?.remote, localStatus: sides?.local, echoLines: echoLines,
                removedRecordings: removedRecordings)
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

    /// Re-ingest the orphaned in-progress chunk into the processor, for the callers that run once the helper
    /// stopped or let go (the salvage). Uses the rotator's live-index base name, NOT the stale sentinel path.
    /// Returns the orphan's (index, baseName) for logging, and whether its files were seen sealed.
    ///
    /// The helper seals the file when it stops — or, after a Stop it never answered, in its invalidation handler once the
    /// connection is dropped — and nothing tells the app when (#232). Read before that, the chunk is cut at its last
    /// periodic header sync (up to 0.5 s short), and its WAV may be archived and deleted under the seal. So the files are
    /// waited for, bounded: processed once their sizes stand still. A wait that runs out processes the chunk as it is —
    /// its audio is never left out — recorded, and said ("couldn't check the last chunk").
    private func reingestOrphanChunk(
        rotator: ChunkRotator, processor: ChunkProcessor, outputDir: URL
    ) async -> (index: Int, baseName: String, sealed: Bool) {
        let orphan = await locateOrphanChunk(rotator: rotator, outputDir: outputDir)
        let sealed = await awaitSeal(of: orphan, in: outputDir)
        if !sealed {
            Logger.state.error("The last chunk's files were still changing, or could not be looked at — processed as they are")
            captureClient.record(.folderNotAnswering, .anomaly, ["during": "last chunk seal", "chunk": "\(orphan.index)"])
        }
        processor.processChunk(orphan)
        return (orphan.index, rotator.currentBaseName, sealed)
    }

    /// The wait for the helper's seal (#232): how long the chunk's files must keep their size, how often they are looked
    /// at, and when the wait gives up. Tests shorten it.
    var sealWait: (stable: Duration, poll: Duration, limit: Duration) = (.seconds(1), .milliseconds(200), .seconds(3))

    /// Whether `chunk`'s files kept their size for `sealWait.stable` — looked at off the main actor, bounded — before
    /// `sealWait.limit` ran out. A file that is not there counts as one that stays so (a system-only chunk has no mic
    /// file); a chunk with no file at all has nothing to seal.
    private func awaitSeal(of chunk: ChunkRotator.FinalizedChunk, in outputDir: URL) async -> Bool {
        let files = [chunk.systemPath, chunk.micPath]
        let giveUp = SuspendingClock.now + sealWait.limit
        var last: [Int]?, since = SuspendingClock.now
        while true {
            let left = giveUp - SuspendingClock.now
            guard left > .zero, let sizes = await readOffMain("salvage: last chunk seal", folder: outputDir, bound: min(folderReadDeadline, left), {
                files.map { ((try? FileManager.default.attributesOfItem(atPath: $0))?[.size] as? Int) ?? -1 }
            }) else { return false }
            if sizes.allSatisfy({ $0 < 0 }) { return true }
            if sizes != last {
                (last, since) = (sizes, .now)
            } else if SuspendingClock.now - since >= sealWait.stable {
                return true
            }
            try? await Task.sleep(for: sealWait.poll)
        }
    }

    /// The orphaned in-progress chunk — the file the helper was writing — located, NOT processed: the crash restart
    /// processes it only once nothing may still write it (final review A-I1: a crash verdict can be false).
    private func locateOrphanChunk(rotator: ChunkRotator, outputDir: URL) async -> ChunkRotator.FinalizedChunk {
        // A timed-out rotation the helper completed late: the orphan is the chunk it was really writing, and
        // the chunk it sealed goes through the pipeline from its own files (L9 review 46). Not a rotation (118).
        // The folder is looked at off the main actor, bounded (L review 158).
        await rotator.reconcileLateRotation()
        let orphan = rotator.currentChunkInfo
        return Self.orphanChunk(
            index: orphan.index, startTime: orphan.startTime,
            liveBaseName: rotator.currentBaseName,   // live-index base, NOT the stale sentinel path
            outputDir: outputDir
        )
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
    /// It was the transcript's WRITE that did not answer (L review 228): that write may still land.
    var duringWrite = false
    var errorDescription: String? { "the recording folder isn’t answering" }
}

/// A finalized session is never finalized again over its transcript (L review 197): it was already transcribed.
struct SessionAlreadyFinalized: Error, LocalizedError {
    let transcript: String
    var errorDescription: String? { "it was already transcribed to \(transcript), and Parley never writes over a finished transcript" }
}

/// The transcription engine is there, but not ready — its speech model is not downloaded (L review 178), or not installed
/// (L review 229): why, as the engine says it.
struct EngineNotReady: Error, LocalizedError {
    let why: String
    /// The readiness look did not answer in time (L review 270): not known to be unready — checked again.
    var checkTimedOut = false
    var errorDescription: String? { why }
}

/// The recovery file in Application Support did not answer a write within its bound (L review 217).
struct RecoveryFileNotAnswering: Error, LocalizedError {
    var errorDescription: String? { "Parley couldn’t write its recovery file — its Application Support folder isn’t answering" }
}

/// The Stop's rebuild could not get its transcription engine (L review 218): why, in words, and what makes it ready (L
/// review 230).
struct EngineUnavailable: Error, LocalizedError {
    let why: String
    var remedy: RecoveryMessages.EngineRemedy = .setupOrDownload
    var errorDescription: String? { why }
}

/// The engine of a salvage with nothing to recognise (L review 232): never asked to transcribe — if it is, it says so.
struct NothingToRecognise: TranscriptionEngine {
    struct NoEngine: Error, LocalizedError {
        var errorDescription: String? { "no transcription engine could be made, and this chunk was not expected to need one" }
    }
    let name = "none"
    func transcribe(audioPath: URL, language: String?, audioSource: AudioSourceType) async throws -> [TranscriptSegment] { throw NoEngine() }
    func isReady() -> Bool { false }
    func prepare() async throws { throw NoEngine() }
}

/// Whether the repair path has answered, shared by the capped wait and the answer (main actor).
@MainActor
private final class RepairAnswer {
    var arrived = false
}
