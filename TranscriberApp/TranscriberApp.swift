import SwiftUI
import UserNotifications
import TranscriberCore

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
            || (FluidAudioEngine.isModelCached() && FluidAudioDiarizer.isDiarizationCached())

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
        let gate = launchGate
        let cm = configManager
        Task { @MainActor in
            await gate.checkAndGate(configManager: cm)
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
