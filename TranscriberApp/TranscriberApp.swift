import SwiftUI
import UserNotifications
import TranscriberCore
import FluidAudio
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

    init() {
        let checker = SystemPermissionChecker()
        permissionManager = PermissionManager(checker: checker)
    }

    func checkAndGate(configManager: ConfigManager) async {
        await permissionManager.checkAll()
        let engine = configManager.config.engine
        let modelReady = !engine.descriptor.requiresModelDownload
            || (FluidAudioEngine.isModelCached() && FluidAudioDiarizer.isFullyReady())

        // Folder access is NOT checked here — the user hasn't confirmed their
        // recording directory until they click Continue in the setup window.
        // Folder TCC is verified in SetupView.verifyFolderAccess() on Continue.
        if permissionManager.allRequiredGranted && modelReady {
            permissionsReady = true
        } else {
            SetupWindowController.shared.show(
                permissionManager: permissionManager,
                configManager: configManager
            ) { [weak self] in
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
    @State private var appState = AppState()
    @State private var launchGate = LaunchGate()
    private let captureClient = AudioCaptureClient()
    private let transcriptionRunner = TranscriptionRunner()
    private let configManager = ConfigManager.shared
    private let calendarService = CalendarService()
    private static let cliSubcommands: Set<String> = ["transcribe", "rename", "rename-gui", "benchmark", "summarize"]

    init() {
        // CLI mode: only enter for known subcommands (not system-injected args)
        if let first = CommandLine.arguments.dropFirst().first,
           Self.cliSubcommands.contains(first) {
            CLIHandler.run()  // Never returns
        }

        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared

        // Crash recovery: check sentinel before anything else
        let client = captureClient
        let state = appState
        Task { @MainActor in
            await Self.recoverIfNeeded(captureClient: client, appState: state)
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
                    Logger.transcription.warning("Manifest verify: missing \(result.missing.count) file(s) — \(result.missing.prefix(3).joined(separator: ", "), privacy: .public)…")
                }
                if !result.corrupt.isEmpty {
                    Logger.transcription.error("Manifest verify: \(result.corrupt.count) file(s) corrupt — \(result.corrupt.prefix(3).joined(separator: ", "), privacy: .public)…")
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
                // but isn't urgent enough to punch through Focus/DND. (The "Recording Resumed" alerts
                // below stay .timeSensitive — those fire mid-recording when audio may be at risk.)
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

        if !LaunchAgentManager.isInstalled() {
            try? LaunchAgentManager.install()
        }
    }

    @MainActor
    private static func recoverIfNeeded(
        captureClient: AudioCaptureClient,
        appState: AppState
    ) async {
        guard let sentinel = RecordingSentinel.read() else { return }

        Logger.state.info("Sentinel found — checking recovery (session: \(sentinel.sessionName, privacy: .private), segment: \(sentinel.segment))")

        // Check if sentinel is stale (from before last boot)
        let bootTime = ProcessInfo.processInfo.systemUptime
        let bootDate = Date().addingTimeInterval(-bootTime)
        if sentinel.startedAt < bootDate {
            Logger.state.info("Stale sentinel from before last boot — cleaning up")
            RecordingSentinel.delete()
            return
        }

        // Flow A: Is XPC service still alive and capturing?
        let isAlive = await captureClient.isCapturing()
        if isAlive {
            Logger.state.info("XPC service alive — re-attaching (Flow A)")
            appState.phase = .recording(since: sentinel.startedAt)
            captureClient.recordLaunchRecovery(["flow": "A", "reattach": "true"])
            setupCrashHandler(captureClient: captureClient, appState: appState)
            return
        }

        // Flow B: XPC is dead — check for partial audio files
        let sysSize = (try? FileManager.default.attributesOfItem(
            atPath: sentinel.systemAudioPath
        )[.size] as? Int) ?? 0

        if sysSize > 44 {
            Logger.state.info("Partial audio found (\(sysSize) bytes) — restarting recording (Flow B)")

            let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
            let seg = sentinel.segment + 1
            let baseName = segmentBaseName(originalPath: sentinel.systemAudioPath, segment: seg)

            let newSentinel = sentinel.incrementedSegment(
                systemAudioPath: outputDir.appendingPathComponent(baseName + ".wav").path,
                micAudioPath: outputDir.appendingPathComponent(baseName + "_mic.wav").path
            )

            do {
                try await captureClient.start(
                    outputDirectory: outputDir,
                    baseName: baseName,
                    microphoneDeviceId: sentinel.micDeviceUID,
                    systemAudioSource: ConfigManager.shared.config.systemAudioSource
                )
                try RecordingSentinel.write(newSentinel)
                appState.phase = .recording(since: sentinel.startedAt)
                appState.interruptionWarning = "Recording was briefly interrupted. Some audio may have been lost."
                captureClient.recordLaunchRecovery(["flow": "B", "segment": "\(seg)"])
                setupCrashHandler(captureClient: captureClient, appState: appState)

                // Send notification
                if Bundle.main.bundleIdentifier != nil {
                    let content = UNMutableNotificationContent()
                    content.title = "Recording Resumed"
                    content.body = "Recording was briefly interrupted. Some audio may have been lost."
                    content.sound = .default
                    content.interruptionLevel = .timeSensitive
                    let request = UNNotificationRequest(
                        identifier: UUID().uuidString, content: content, trigger: nil
                    )
                    try? await UNUserNotificationCenter.current().add(request)
                }
            } catch {
                Logger.state.error("Flow B recovery failed: \(error, privacy: .public)")
                appState.criticalError = "Recording failed — could not restart after crash recovery."
                RecordingSentinel.delete()
                CriticalAlertController.shared.show(
                    title: "Recording Failed",
                    message: "Crash recovery attempted but could not restart recording."
                )
            }
        } else {
            Logger.state.info("No usable audio files — cleaning up sentinel")
            RecordingSentinel.delete()
        }
    }

    @MainActor
    private static func setupCrashHandler(
        captureClient: AudioCaptureClient,
        appState: AppState
    ) {
        captureClient.onServiceCrash = {
            Task { @MainActor in
                guard appState.isRecording else { return }
                guard let sentinel = RecordingSentinel.read() else { return }

                let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
                let seg = sentinel.segment + 1
                let baseName = segmentBaseName(originalPath: sentinel.systemAudioPath, segment: seg)

                let newSentinel = sentinel.incrementedSegment(
                    systemAudioPath: outputDir.appendingPathComponent(baseName + ".wav").path,
                    micAudioPath: outputDir.appendingPathComponent(baseName + "_mic.wav").path
                )

                do {
                    try await captureClient.start(
                        outputDirectory: outputDir,
                        baseName: baseName,
                        microphoneDeviceId: sentinel.micDeviceUID,
                        systemAudioSource: ConfigManager.shared.config.systemAudioSource
                    )
                    try RecordingSentinel.write(newSentinel)
                    appState.interruptionWarning = "Recording briefly interrupted. Resuming."

                    if Bundle.main.bundleIdentifier != nil {
                        let content = UNMutableNotificationContent()
                        content.title = "Recording Resumed"
                        content.body = "Recording was briefly interrupted and has been restarted."
                        content.sound = .default
                        content.interruptionLevel = .timeSensitive
                        let request = UNNotificationRequest(
                            identifier: UUID().uuidString, content: content, trigger: nil
                        )
                        try? await UNUserNotificationCenter.current().add(request)
                    }
                } catch {
                    Logger.state.error("Recovery crash handler failed: \(error, privacy: .public)")
                    appState.criticalError = "Recording failed — capture crashed and could not restart."
                    appState.phase = .idle
                    RecordingSentinel.delete()
                    CriticalAlertController.shared.show(
                        title: "Recording Failed",
                        message: "Capture crashed during recovery and could not restart."
                    )
                }
            }
        }
        // #86: benign route changes during a recovered recording resume in place; only a fatal
        // give-up escalates to the relaunch handler above.
        captureClient.onRestartInPlace = {
            Task { @MainActor in
                guard appState.isRecording else { return }
                appState.interruptionWarning = "Audio device changed — recording resumed automatically."
            }
        }
        captureClient.onBriefInterruption = {
            Task { @MainActor in
                guard appState.isRecording else { return }
                appState.interruptionWarning = "Recording briefly interrupted — continuing."
            }
        }
        // #86: the helper could not restart the mid-recording system (remote) stream within budget.
        // The local mic keeps recording on its own AVCaptureSession — warn, never stop.
        captureClient.onSystemAudioUnrecoverable = { _ in
            Task { @MainActor in
                guard appState.isRecording else { return }
                appState.interruptionWarning = "Remote audio couldn’t be recovered — only your microphone is recording."
            }
        }
        captureClient.onFatalFailure = { _ in
            Task { @MainActor in
                guard appState.isRecording else { return }
                captureClient.onServiceCrash?()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra("Transcriber", systemImage: appState.menuBarIcon) {
            if launchGate.permissionsReady {
                MenuView(
                    appState: appState,
                    captureClient: captureClient,
                    transcriptionRunner: transcriptionRunner,
                    configManager: configManager,
                    calendarService: calendarService
                )
            } else {
                Button("Setup required...") {}
                    .disabled(true)
                Divider()
                Button("Quit") {
                    LaunchAgentManager.uninstall()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(
                configManager: configManager,
                permissionManager: launchGate.permissionManager
            )
        }
    }
}
