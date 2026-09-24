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
    @State private var appState: AppState
    @State private var launchGate: LaunchGate
    private let captureClient: AudioCaptureClient
    /// Owns the recording lifecycle and every crash path, launch recovery included (§8.3). Built here,
    /// once, and injected into `MenuView` — a view-owned coordinator would not exist yet at launch.
    private let coordinator: RecordingCoordinator
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
                RenameWindowController.shared.show(jsonPath: jsonPath) {
                    // Auto-summarize after rename completes (so summary has real speaker names)
                    MenuView.autoSummarize(jsonPath: jsonPath, config: config)
                }
            },
            onSystemAudioPermissionDenied: {
                Task { await PermissionRepairWindowController.shared.verify(trigger: .captureEvidence) }
            },
            presentAlarmsUI: { alarms, new in
                CaptureAlarmWindowController.shared.present(alarms, newlyRaised: new, appState: state)
            }
        )
        _launchGate = State(initialValue: LaunchGate(captureClient: client))

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

    @MainActor
    static func verifyCrashProtection(appState: AppState) async {
        let health = await LaunchAgentManager.verifyAndRepair(holdsInstanceLock: holdsInstanceLock)
        switch health {
        case .healthy:
            appState.clearAppAlarm(.crashProtectionOff)
        case .loadedButNotThisProcess:
            // Normal after a Finder/Sparkle launch, and right after a first install (the bootstrap in
            // verifyAndRepair already spawned launchd's copy, which is waiting for our lock).
            guard holdsInstanceLock else {
                // No lock, no hand-over: `kickstart -k` could kill a recording instance (C2 round 5).
                Logger.state.error("LaunchAgent hand-over impossible without the single-instance lock — crash protection stays off")
                raiseCrashProtectionOff(appState, LaunchAgentHealth.userMessage(for: health, holdsInstanceLock: false))
                return
            }
            // Busy (recording, or finishing a transcript): the message promises automatic re-enable,
            // so re-check once it is over. No row meanwhile (C2 ruling: this is the normal state).
            if !appState.isIdle {
                appState.clearAppAlarm(.crashProtectionOff)
                scheduleCrashProtectionRecheck(appState: appState)
                return
            }
            let defaults = UserDefaults.standard
            let last = defaults.object(forKey: lastHandOverKey) as? Date
            guard LaunchAgentHealth.shouldAttemptHandOver(
                isRecording: !appState.isIdle, isCLI: false, isLaunchdJob: isLaunchdJob,
                holdsInstanceLock: holdsInstanceLock, lastHandOverAt: last, now: Date()
            ) else {
                Logger.state.error("LaunchAgent hand-over not attempted now (cooldown, or this is the launchd job) — crash protection stays off")
                raiseCrashProtectionOff(appState, LaunchAgentHealth.userMessage(for: health, holdsInstanceLock: true))
                scheduleCrashProtectionRecheck(appState: appState)
                return
            }
            defaults.set(Date(), forKey: lastHandOverKey)   // BEFORE the kickstart: the cooldown must outlive this process
            if await LaunchAgentManager.handOverToJob() {
                // `kickstart -k` gave launchd's copy a fresh 10 s window to take the lock: release it
                // and exit NOW (no NSApp.terminate, nothing awaited) — lingering past that window
                // would leave no instance at all (C2 round 5, item 4).
                Logger.state.info("Handed over to launchd's own job — this process exits now")
                releaseInstanceLock()
                exit(0)
            }
            Logger.state.error("LaunchAgent hand-over failed — crash protection stays off")
            raiseCrashProtectionOff(appState, LaunchAgentHealth.userMessage(for: health, holdsInstanceLock: true))
            scheduleCrashProtectionRecheck(appState: appState)
        default:
            // verifyAndRepair returns the state AFTER repair: anything else here means repair failed
            // (or was skipped without the lock) (scan A18).
            raiseCrashProtectionOff(appState, LaunchAgentHealth.userMessage(for: health, holdsInstanceLock: holdsInstanceLock))
        }
    }

    @MainActor
    private static func raiseCrashProtectionOff(_ appState: AppState, _ message: String?) {
        let text = message ?? "Crash protection is off — if Parley crashes mid-recording it will not relaunch."
        if appState.raiseAppAlarm(.crashProtectionOff, message: text) {
            MenuView.postNotification(title: "Crash protection is off", body: text)
        }
    }

    /// Bounded, not a loop: one re-check in 5 minutes, which re-schedules itself only while the
    /// state is still `.loadedButNotThisProcess` (healthy → nothing; handed over → this process is gone).
    @MainActor
    private static func scheduleCrashProtectionRecheck(appState: AppState) {
        Task(priority: .utility) { @MainActor in
            try? await Task.sleep(for: .seconds(300))
            await verifyCrashProtection(appState: appState)
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
                quitAfterUninstallingLaunchAgent()
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 320)
    }
}
