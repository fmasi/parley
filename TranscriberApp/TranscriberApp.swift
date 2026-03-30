import SwiftUI
import TranscriberCore

@MainActor
@Observable
final class LaunchGate {
    var permissionsReady = false
    let permissionManager: PermissionManager

    init() {
        let checker = SystemPermissionChecker()
        permissionManager = PermissionManager(checker: checker)
    }

    func checkAndGate() async {
        await permissionManager.checkAll()
        if permissionManager.allRequiredGranted {
            permissionsReady = true
        } else {
            SetupWindowController.shared.show(
                permissionManager: permissionManager
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

    init() {
        let gate = launchGate
        Task { @MainActor in
            await gate.checkAndGate()
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
