import SwiftUI
import UserNotifications
import TranscriberCore
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

@main
struct TranscriberApp: App {
    @State private var appState = AppState()
    @State private var launchGate = LaunchGate()
    private let captureClient = AudioCaptureClient()
    private let transcriptionRunner = TranscriptionRunner()
    private let configManager = ConfigManager.shared
    private let calendarService = CalendarService()
    private static let cliSubcommands: Set<String> = ["transcribe", "rename", "rename-gui", "benchmark"]

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

        Logger.state.info("Sentinel found — checking recovery (session: \(sentinel.sessionName, privacy: .public), segment: \(sentinel.segment))")

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
                    microphoneDeviceId: sentinel.micDeviceUID
                )
                try RecordingSentinel.write(newSentinel)
                appState.phase = .recording(since: sentinel.startedAt)
                appState.interruptionWarning = "Recording was briefly interrupted. Some audio may have been lost."
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
                RecordingSentinel.delete()
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
                        microphoneDeviceId: sentinel.micDeviceUID
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
                    appState.errorMessage = "Recording lost — failed to restart: \(error.localizedDescription)"
                    appState.phase = .idle
                    RecordingSentinel.delete()
                }
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
