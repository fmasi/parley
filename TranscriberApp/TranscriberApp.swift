import SwiftUI
import AppKit
import UserNotifications
import TranscriberCore
import FluidAudio
import Sparkle
import os

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@MainActor
@Observable
final class LaunchGate {
    var permissionsReady = false
    let permissionManager: PermissionManager

    init(captureClient: AudioCaptureClient) {
        var checker = SystemPermissionChecker()
        // Live System Audio Recording checks go through the helper: the app process's own TCC answer
        // is cached for its lifetime (#220).
        checker.helperSystemAudioStatus = { [weak captureClient] in
            await captureClient?.systemAudioPermissionStatus()
        }
        permissionManager = PermissionManager(checker: checker)
    }

    /// Persisted once setup has been completed. After that a missing permission is REPAIRED, never
    /// answered with the "Setup required" lockout (#174, #220).
    private static let onboardingCompletedKey = "onboardingCompleted"

    static func markOnboarded() {
        UserDefaults.standard.set(true, forKey: onboardingCompletedKey)
    }

    func checkAndGate(configManager: ConfigManager) async {
        permissionManager.systemAudioSource = configManager.config.systemAudioSource
        await permissionManager.checkAll()
        let engine = configManager.config.engine
        let modelReady = !engine.descriptor.requiresModelDownload
            || (FluidAudioEngine.isModelCached() && FluidAudioDiarizer.isFullyReady())
        let onboarded = CaptureReadiness.isOnboarded(
            flag: UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey),
            microphoneGranted: permissionManager.microphone.isGranted
        )

        // Folder access is NOT checked here — the user hasn't confirmed their
        // recording directory until they click Continue in the setup window.
        // Folder TCC is verified in SetupView.verifyFolderAccess() on Continue.
        switch CaptureReadiness.launchDecision(
            onboardingCompleted: onboarded,
            missing: permissionManager.missingRequired,
            modelReady: modelReady
        ) {
        case .ready:
            Self.markOnboarded()
            permissionsReady = true
        case .readyNeedsRepair:
            Self.markOnboarded()
            permissionsReady = true
            await PermissionRepairWindowController.shared.verify(trigger: .launch)
        case .onboarding:
            SetupWindowController.shared.show(
                permissionManager: permissionManager,
                configManager: configManager
            ) { [weak self] in
                Self.markOnboarded()
                self?.permissionsReady = true
            }
        }
    }
}

/// Holds the most recent model-manifest verification result so the UI can surface
/// missing/corrupt model files to the user (Settings shows it; a notification alerts
/// at launch). Populated by the launch-time `verify()` in `TranscriberApp.init`.
@MainActor
@Observable
final class ManifestHealthStore {
    static let shared = ManifestHealthStore()
    private init() {}

    /// Latest launch-time verification result; nil until the first check completes.
    private(set) var verification: ManifestVerification?

    /// User-facing description of any integrity problem, or nil when healthy/unknown.
    var problemMessage: String? {
        guard let v = verification, v.hasProblems else { return nil }
        return Self.problemMessage(for: v)
    }

    func update(_ result: ManifestVerification) {
        verification = result
    }

    /// Builds the Settings detail message. `nonisolated` so it can be reused off the
    /// main actor (e.g. when composing the launch notification).
    nonisolated static func problemMessage(for v: ManifestVerification) -> String {
        var parts: [String] = []
        if !v.missing.isEmpty { parts.append("\(v.missing.count) missing") }
        if !v.corrupt.isEmpty { parts.append("\(v.corrupt.count) corrupt") }
        let summary = parts.isEmpty ? "integrity issue" : parts.joined(separator: ", ")
        return "Model files failed verification (\(summary)). Re-download the model from Setup to restore it."
    }
}

@main
struct TranscriberApp: App {
    /// `applicationShouldTerminate`: a logout, shutdown or outside quit stops the helper first (L10 review 53).
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var terminationDelegate
    @State private var appState: AppState
    @State private var launchGate: LaunchGate
    private let captureClient: AudioCaptureClient
    /// Owns the recording lifecycle and every crash path, launch recovery included (§8.3). Built here,
    /// once, and injected into `MenuView` — a view-owned coordinator would not exist yet at launch.
    private let coordinator: RecordingCoordinator
    /// Sleep and wake forwarded to the coordinator for the app's lifetime (§8.10); a volume mount and a wake retry
    /// the pending sessions; the power-off notice only notes the termination's kind and marks a transcript being
    /// finished — the stop happens when the quit itself arrives (L review 110).
    private let systemEvents: SystemEventObserver
    private let configManager = ConfigManager.shared
    private let calendarService = CalendarService()
    // Recording app: never silent-install (no userDriverDelegate override) — the standard user
    // driver always prompts before installing. startingUpdater: false -- stored properties init
    // before init()'s body runs, so starting it here would fire Sparkle's background timer/threads
    // even for a CLI invocation (parley transcribe, etc.) that's about to exit. Started explicitly
    // below, only once the CLI-mode check has passed.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )
    private static let cliSubcommands: Set<String> = [
        "transcribe", "rename", "rename-gui", "benchmark", "summarize", "download-models",
    ]

    init() {
        let client = AudioCaptureClient()
        captureClient = client
        let state = AppState()
        _appState = State(initialValue: state)
        let runner = TranscriptionRunner()
        // The app-target UI side effects the coordinator needs (notifications, the critical panel, the
        // rename dialog + auto-summary, the repair and alarm windows) are injected here.
        coordinator = RecordingCoordinator(
            appState: state,
            captureClient: client,
            transcriptionRunner: runner,
            configManager: ConfigManager.shared,
            notify: { title, body in
                MenuView.postNotification(title: title, body: body)
            },
            notifyCritical: { title, body in
                MenuView.sendCriticalNotification(title: title, body: body)
            },
            presentTranscript: { jsonPath, config in
                // Queued: several salvaged transcripts open one rename panel at a time (L review 90).
                RenameWindowController.shared.enqueue(jsonPath: jsonPath) {
                    // Auto-summarize after rename completes (so summary has real speaker names)
                    MenuView.autoSummarize(jsonPath: jsonPath, config: config)
                }
            },
            onSystemAudioPermissionDenied: {
                await PermissionRepairWindowController.shared.verify(trigger: .captureEvidence)
            },
            presentAlarmsUI: { due, new in
                CaptureAlarmWindowController.shared.present(due, newlyRaised: new, appState: state)
            },
            notifyAlarm: { alarm in CaptureAlarmWindowController.shared.notify(alarm) }
        )
        _launchGate = State(initialValue: LaunchGate(captureClient: client))
        Self.busyCoordinator = coordinator
        // A recording under a process that has not handed over runs without crash relaunch: re-checked on the
        // transition INTO a recording, so the row says so (final review A-I2).
        coordinator.onRecordingStarted = {
            Task { @MainActor in await Self.verifyCrashProtection(appState: state) }
        }
        systemEvents = SystemEventObserver(coordinator: coordinator)

        // CLI mode: only enter for known subcommands (not system-injected args)
        if let first = CommandLine.arguments.dropFirst().first,
           Self.cliSubcommands.contains(first) {
            CLIHandler.run()  // Never returns
        }

        // Single-instance guard (#109): the crash-recovery LaunchAgent can make launchd spawn a
        // duplicate GUI copy while a user-launched instance is already running. Keep only the oldest
        // instance; any duplicate exits cleanly here (status 0, so KeepAlive won't relaunch it) —
        // except launchd's own job arriving during a hand-over, which waits for the lock (L3). Runs
        // AFTER the CLI check so `parley transcribe`-style invocations are never blocked by a running
        // GUI app, and BEFORE Sparkle/notification/recovery setup so a doomed duplicate does no work.
        // A real crash still recovers: the kernel releases a dead process's lock, so the relaunched
        // instance sees no rival and proceeds.
        Self.yieldIfDuplicateInstance()

        // Runs the check-on-launch + 24h background cadence configured via SUScheduledCheckInterval
        // in Info.plist. Deferred to here (not the property initializer above) so CLI invocations
        // never start Sparkle's updater at all.
        do {
            try updaterController.updater.start()
        } catch {
            // NSError.localizedDescription can include filesystem paths -- .private, not .public.
            // Non-critical (a recording app shouldn't crash over the updater), but the only visible
            // symptom otherwise is "Check for Updates..." staying permanently disabled with no clue why.
            Logger.state.error("Sparkle updater failed to start (\"Check for Updates...\" will stay disabled): \(error, privacy: .private)")
        }

        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared

        PermissionRepairWindowController.shared.configure(
            permissionManager: launchGate.permissionManager, captureClient: client, appState: appState
        )

        // Crash recovery: check sentinel before anything else. Kept in a local: the crash-protection
        // check below waits for it, so a hand-over (an exit) can never cut short a resuming recording.
        let c = coordinator
        let recovery = Task { @MainActor in
            await c.recoverAtLaunch()
        }

        Task.detached(priority: .background) {
            let cacheRoot = AsrModels.defaultCacheDirectory()
            let result = await ModelManifestService.shared.verify(
                repo: FluidAudioEngine.parakeetRepoSlug,
                cacheRoot: cacheRoot
            )
            if !result.manifestPresent {
                Logger.transcription.info("Manifest verify: no manifest yet (will be written on next download)")
            } else if result.isOK {
                Logger.transcription.info("Manifest verify: OK")
            } else {
                if !result.missing.isEmpty {
                    Logger.transcription.warning("Manifest verify: missing \(result.missing.count) file(s) — \(result.missing.prefix(3).joined(separator: ", "), privacy: .sensitive)…")
                }
                if !result.corrupt.isEmpty {
                    Logger.transcription.error("Manifest verify: \(result.corrupt.count) file(s) corrupt — \(result.corrupt.prefix(3).joined(separator: ", "), privacy: .sensitive)…")
                }
            }
            // Surface the result to the UI layer (Settings shows it; a notification alerts now).
            await MainActor.run { ManifestHealthStore.shared.update(result) }
            if result.hasProblems, Bundle.main.bundleIdentifier != nil {
                let content = UNMutableNotificationContent()
                content.title = "Model Integrity Problem"
                content.body = ManifestHealthStore.problemMessage(for: result)
                content.sound = .default
                // .active (not .timeSensitive): a model-integrity problem at launch is worth surfacing
                // but isn't urgent enough to punch through Focus/DND. (The "Recording Resumed" and
                // capture-alarm notifications stay .timeSensitive — they fire mid-recording when audio
                // may be at risk.)
                content.interruptionLevel = .active
                let request = UNNotificationRequest(
                    identifier: "manifest-verify", content: content, trigger: nil
                )
                try? await UNUserNotificationCenter.current().add(request)
            }
        }

        let gate = launchGate
        let cm = configManager
        Task { @MainActor in
            await gate.checkAndGate(configManager: cm)
        }

        // L11: launchd's opinion is what relaunches us. Verify + repair at every launch; when we are
        // not launchd's own process (a Finder or Sparkle launch — the normal case, C2), hand over to
        // it; say "crash protection is off" only when that is impossible or failed. After launch
        // recovery: never hand over (exit) while a recording may be resuming. This replaces the
        // legacy `isInstalled()` → `install()`, which ran enable + bootstrap with no lock check: no
        // launchctl verb runs at launch outside `verifyAndRepair` / `handOverToJob`.
        Task(priority: .utility) { @MainActor in
            await recovery.value
            await Self.verifyCrashProtection(appState: state)
        }
    }

    // MARK: - Crash protection (L3, L11)

    /// Persisted, not in memory: a process that hands over successfully exits, so an in-memory
    /// `lastHandOverAt` could never enforce the cooldown (C2 round 2).
    private static let lastHandOverKey = "LaunchAgent.lastHandOverAt"
    /// Kickstarts that failed in this process; capped by `LaunchAgentHealth.maxHandOverAttempts`.
    private static var failedHandOvers = 0
    /// One check at a time: the idle watch and the cooldown retry can both fire.
    private static var crashProtectionCheckRunning = false
    /// Waits for the transition to idle before re-checking (never a blind timer).
    private static var idleWatch: IdleWatch?
    /// Since when open windows alone have deferred the hand-over (bounded: `windowDeferralLimit`).
    private static var windowDeferralSince: Date?
    /// The one pending bounded re-check of a window deferral.
    private static var windowDeferralRecheck: Task<Void, Never>?

    /// The coordinator, for the busy checks: a recording start in flight (the hand-over), work an exit would
    /// cut short (termination, every Quit). Weak: the App owns it.
    private(set) static weak var busyCoordinator: RecordingCoordinator?

    /// Whether Parley is doing work a hand-over (an exit) would cut short: a recording or its
    /// transcription, a recording START in flight (the phase is still `.idle` while the helper starts),
    /// post-recording work (the auto-summary), or a panel still preparing before its window exists
    /// (rename parsing, the SessionName / MicSwitch device scans) (L3 fix round 1, L round 5).
    @MainActor
    static func isBusy(_ appState: AppState) -> Bool {
        !appState.isIdle || PostRecordingWork.inFlight > 0 || (busyCoordinator?.isStartInFlight ?? false)
            || RenameWindowController.shared.isPreparing || SessionNameWindowController.shared.isPreparing
            || MicSwitchWindowController.shared.isPreparing
    }

    /// Any Parley window the user may be working in — Settings, the menu-bar dropdown, a panel: a
    /// hand-over would close it mid-edit (L2/L4 fix round 2, item 6). Only real ones count: on screen, a
    /// non-zero frame, at most at the pop-up menu level (L rounds 3-4), never the status item's own
    /// button window. A window that stays up regardless defers the hand-over for at most
    /// `LaunchAgentHealth.windowDeferralLimit`; after that the crash-protection row says why.
    @MainActor
    static func anyParleyWindowVisible() -> Bool { !deferringWindows().isEmpty }

    @MainActor
    static func deferringWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            LaunchAgentHealth.windowDefersHandOver(
                isVisible: window.isVisible, width: window.frame.width, height: window.frame.height,
                level: window.level.rawValue, maxLevel: NSWindow.Level.popUpMenu.rawValue, className: window.className)
        }
    }

    @MainActor
    static func verifyCrashProtection(appState: AppState) async {
        guard !crashProtectionCheckRunning else { return }
        crashProtectionCheckRunning = true
        defer { crashProtectionCheckRunning = false }

        let health = await LaunchAgentManager.verifyAndRepair(holdsInstanceLock: holdsInstanceLock)
        let defaults = UserDefaults.standard
        let now = Date()
        let busy = isBusy(appState)
        let deferring = deferringWindows()
        let windowsOpen = !deferring.isEmpty
        if windowsOpen {
            // What holds the hand-over back — class and level only: a window title can name a meeting (L round 6).
            let described = deferring.map { "\($0.className)@\($0.level.rawValue)" }.joined(separator: ", ")
            Logger.state.info("Crash-protection hand-over deferred by windows: \(described, privacy: .public)")
        }
        // Windows alone (no work) defer the hand-over for a bounded time: track since when.
        if windowsOpen && !busy {
            if windowDeferralSince == nil { windowDeferralSince = now }
        } else {
            windowDeferralSince = nil
        }
        let action = LaunchAgentHealth.crashProtectionAction(
            state: health, holdsInstanceLock: holdsInstanceLock, isLaunchdJob: isLaunchdJob, isBusy: busy,
            isRecording: appState.isRecording, anyWindowVisible: windowsOpen, windowDeferredFor: windowDeferralSince.map { now.timeIntervalSince($0) } ?? 0,
            lastHandOverAt: defaults.object(forKey: lastHandOverKey) as? Date, now: now, failedHandOvers: failedHandOvers
        )
        switch action {
        case .healthy:
            appState.clearAppAlarm(.crashProtectionOff)
        case .deferUntilIdle(let message, let recheckAfter):
            // Normal after a Finder/Sparkle launch while something is in flight: no row (C2 ruling) —
            // unless windows have held it for `windowDeferralLimit`, or a recording runs unprotected (final
            // review A-I2): then the row says why (never silent).
            if let message { raiseCrashProtectionOff(appState, message) } else { appState.clearAppAlarm(.crashProtectionOff) }
            recheckCrashProtectionWhenIdle(appState: appState)
            if let recheckAfter {
                windowDeferralRecheck?.cancel()
                windowDeferralRecheck = Task(priority: .utility) { @MainActor in
                    try? await Task.sleep(for: .seconds(recheckAfter))
                    guard !Task.isCancelled else { return }
                    await verifyCrashProtection(appState: appState)
                }
            }
        case .retryAfter(let seconds, let message):
            if let message { raiseCrashProtectionOff(appState, message) }
            Logger.state.info("LaunchAgent hand-over cooldown — one re-check in \(Int(seconds.rounded(.up)), privacy: .public) s")
            Task(priority: .utility) { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                await verifyCrashProtection(appState: appState)
            }
        case .alarm(let message):
            Logger.state.error("Crash protection is off (\(LaunchAgentHealth.logName(for: health), privacy: .public)) — no automatic retry")
            raiseCrashProtectionOff(appState, message)
        case .handOver:
            defaults.set(Date(), forKey: lastHandOverKey)   // BEFORE the kickstart: the cooldown must outlive this process
            guard await LaunchAgentManager.handOverToJob() else {
                failedHandOvers += 1
                Logger.state.error("LaunchAgent hand-over failed (\(failedHandOvers, privacy: .public) of \(LaunchAgentHealth.maxHandOverAttempts, privacy: .public))")
                crashProtectionCheckRunning = false
                await verifyCrashProtection(appState: appState)   // decides: one retry after the cooldown, or the capped row
                return
            }
            // Re-checked AFTER the kickstart returned: a recording, a transcript or a panel may have
            // started meanwhile. Busy → do NOT exit: launchd's copy times out and exits 0 by itself
            // (`SingleInstancePolicy`), and this process re-checks on the transition to idle.
            guard !isBusy(appState), !anyParleyWindowVisible() else {
                Logger.state.info("Became busy during the hand-over — staying; launchd's copy will exit 0")
                recheckCrashProtectionWhenIdle(appState: appState)
                return
            }
            // `kickstart -k` gave launchd's copy a fresh 10 s window to take the lock: release it and
            // exit NOW (no NSApp.terminate, nothing awaited) — lingering past that window would leave
            // no instance at all (C2 round 5, item 4).
            Logger.state.info("Handed over to launchd's own job — this process exits now")
            // `exit(0)` skips `applicationWillTerminate`: the live logs' queued lines are flushed here, bounded (L review
            // 141) — before the lock goes, so launchd's copy never reads a log still being written.
            if !LiveDiagnosticsLog.flushAll(within: AppTerminationDelegate.exitFlushBound) {
                Logger.state.error("A recording folder did not answer the hand-over's flush — its last queued diagnostic lines are lost")
            }
            releaseInstanceLock()
            exit(0)
        }
    }

    /// Raising is enough: the coordinator presents a newly raised alarm at once (window + ONE
    /// notification), then backs off (L round 3). No second notification from here.
    @MainActor
    private static func raiseCrashProtectionOff(_ appState: AppState, _ message: String) {
        appState.raiseAppAlarm(.crashProtectionOff, message: message)
    }

    /// Re-check on the TRANSITION to idle: a Parley window closing (or the menu-bar panel, which hides
    /// rather than closes, resigning key), post-recording work finishing, or the phase changing — not a
    /// timer. One watch at a time.
    @MainActor
    private static func recheckCrashProtectionWhenIdle(appState: AppState) {
        guard idleWatch == nil else { return }
        let watch = IdleWatch(isBusy: { isBusy(appState) || anyParleyWindowVisible() }) {
            idleWatch = nil
            Task { @MainActor in await verifyCrashProtection(appState: appState) }
        }
        idleWatch = watch
        watch.start {
            _ = appState.phase
            _ = busyCoordinator?.isStartInFlight
        }
    }

    /// Holds the single-instance lock fd for the whole process lifetime. It must stay open (closing
    /// it, or dropping the last reference, releases the kernel lock), so it lives as a static here.
    private static var instanceLockFD: Int32 = -1

    /// True only when this launch's `SingleInstanceGuard.acquireLock` returned `.acquired`. Every
    /// launchctl verb that could kill another instance (repair, hand-over, Quit's bootout) requires it:
    /// without it this process runs unguarded and another live instance may be recording (C2 round 5).
    private(set) static var holdsInstanceLock = false

    /// launchd sets `XPC_SERVICE_NAME` to the job label for the processes it spawns (verified:
    /// `launchctl print gui/<uid>/eu.fmasi.parley` lists `environment = { XPC_SERVICE_NAME =>
    /// eu.fmasi.parley }`), so this is launchd's own KeepAlive job.
    static let isLaunchdJob = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == LaunchAgentManager.label

    /// If another instance of this app is already running, exit cleanly so exactly one survives (#109) —
    /// unless THIS process is launchd's own job arriving during a hand-over (`SingleInstancePolicy`,
    /// C2): then it waits up to 10 s for the outgoing process to exit and release the lock, instead of
    /// yielding to a process that is about to disappear, and exits 0 if it never does (a non-zero
    /// exit would make KeepAlive respawn it every 10 s). The wait blocks `App.init` on the main
    /// thread, deliberately: this process has no UI yet and nothing else to do.
    ///
    /// Uses a `flock`-based lock (unit-tested in `SingleInstanceGuard`) rather than scanning
    /// `NSRunningApplication`: a launchd-spawned duplicate runs this inside `init()` before the first
    /// instance is registered with LaunchServices, so a running-app scan sees no rival and both
    /// survive. The kernel lock has no such race.
    private static func yieldIfDuplicateInstance() {
        let dir = AppPaths.dataDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockPath = dir.appendingPathComponent("instance.lock").path
        Logger.state.info("Instance guard: launchd job = \(isLaunchdJob, privacy: .public)")
        var attempt = SingleInstanceGuard.acquireLock(at: lockPath)
        if case .heldByOther = attempt,
           case .waitForLock(let seconds, let onTimeout) = SingleInstancePolicy.decide(isLaunchdJob: isLaunchdJob, lockHeldByOther: true) {
            let deadline = Date().addingTimeInterval(seconds)
            while case .heldByOther = attempt, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
                attempt = SingleInstanceGuard.acquireLock(at: lockPath)
            }
            if case .heldByOther = attempt {
                switch onTimeout {
                case .exitZero:
                    Logger.state.info("launchd job: the running instance kept the lock for \(seconds, privacy: .public) s — exiting 0 (never respawned)")
                    exit(0)
                }
            }
        }
        switch attempt {
        case .heldByOther:
            Logger.state.info("Another Parley instance is already running — this duplicate is exiting (#109).")
            exit(0)
        case .acquired(let fd):
            instanceLockFD = fd  // held for the process lifetime; intentionally never closed
            holdsInstanceLock = true
        case .unavailable:
            Logger.state.error("Single-instance lock unavailable — proceeding unguarded (#109).")
        }
    }

    /// Only for the hand-over, right before `exit(0)`: launchd's copy is waiting for this lock.
    private static func releaseInstanceLock() {
        guard instanceLockFD >= 0 else { return }
        flock(instanceLockFD, LOCK_UN)
        close(instanceLockFD)
        instanceLockFD = -1
        holdsInstanceLock = false
    }

    var body: some Scene {
        MenuBarExtra("Parley", systemImage: appState.menuBarIcon) {
            if launchGate.permissionsReady {
                MenuView(
                    appState: appState,
                    coordinator: coordinator,
                    configManager: configManager,
                    calendarService: calendarService,
                    updater: updaterController.updater,
                    permissionManager: launchGate.permissionManager
                )
            } else {
                SetupRequiredPanel(launchGate: launchGate, configManager: configManager)
            }
        }
        // .window (not .menu): the panel is the app's face — status header, live
        // timer, prominent record button. See docs/design/design-system-0.8.x.md.
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                configManager: configManager,
                permissionManager: launchGate.permissionManager
            )
        }
        // Cmd-Q from any Parley window (Settings, Setup) is the one Quit too — it asks while recording and stops
        // first, never the app menu's plain terminate that skipped the confirm (L review 108).
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Parley") { quitParley() }
                    .keyboardShortcut("q")
            }
        }
    }
}

/// Menu bar panel shown before setup is complete. Unlike the old disabled menu
/// item, it lets the user reopen the setup window if they closed it.
private struct SetupRequiredPanel: View {
    let launchGate: LaunchGate
    let configManager: ConfigManager
    @Environment(\.dismiss) private var dismissPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatusDot(color: .orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Parley")
                        .font(.headline)
                    Text("Setup required")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)

            Text("Finish setup to start recording.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            MenuActionRow(icon: "checklist", title: "Open Setup…") {
                dismissPanel()
                SetupWindowController.shared.show(
                    permissionManager: launchGate.permissionManager,
                    configManager: configManager
                ) {
                    LaunchGate.markOnboarded()
                    launchGate.permissionsReady = true
                }
            }

            Divider()

            MenuActionRow(icon: "power", title: "Quit Parley") {
                quitParley()
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 320)
    }
}

/// Fires `onIdle` once, on the first transition to "not busy": a window closing, resigning key or
/// changing occlusion (the menu-bar panel only hides — L round 4), post-recording work finishing, or
/// the recording phase changing (L3 fix round 1). Observers only — no timer.
@MainActor
private final class IdleWatch {
    private let isBusy: @MainActor () -> Bool
    private let onIdle: @MainActor () -> Void
    private var tokens: [NSObjectProtocol] = []
    private var done = false

    init(isBusy: @escaping @MainActor () -> Bool, onIdle: @escaping @MainActor () -> Void) {
        self.isBusy = isBusy
        self.onIdle = onIdle
    }

    /// `observed`: reads the observable state whose change is also a transition (the phase, a start in
    /// flight).
    func start(observing observed: @escaping @MainActor () -> Void) {
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, .parleyActivityEnded] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // willClose fires while the window is still up: look again on the next turn.
                Task { @MainActor in self?.evaluate() }
            })
        }
        observe(observed)
    }

    private func observe(_ observed: @escaping @MainActor () -> Void) {
        withObservationTracking {
            observed()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.done else { return }
                self.evaluate()
                if !self.done { self.observe(observed) }
            }
        }
    }

    private func evaluate() {
        guard !done, !isBusy() else { return }
        done = true
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        onIdle()
    }
}
