import SwiftUI
import UserNotifications

@main
struct TranscriberApp: App {
    @State private var appState = AppState()
    private let captureClient = AudioCaptureClient()
    private let transcriptionRunner = TranscriptionRunner()
    private let configManager = ConfigManager.shared

    init() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    var body: some Scene {
        MenuBarExtra("Transcriber", systemImage: appState.menuBarIcon) {
            MenuView(
                appState: appState,
                captureClient: captureClient,
                transcriptionRunner: transcriptionRunner,
                configManager: configManager
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(configManager: configManager)
        }
    }
}
