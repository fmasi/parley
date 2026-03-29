import SwiftUI
import UserNotifications

@main
struct TranscriberApp: App {
    @State private var appState = AppState()
    private let captureClient = AudioCaptureClient()
    private let transcriptionRunner = TranscriptionRunner()
    private let configManager = ConfigManager.shared
    private let calendarService = CalendarService()

    init() {
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            ) { _, _ in }
        }
        calendarService.requestAccess()
    }

    var body: some Scene {
        MenuBarExtra("Transcriber", systemImage: appState.menuBarIcon) {
            MenuView(
                appState: appState,
                captureClient: captureClient,
                transcriptionRunner: transcriptionRunner,
                configManager: configManager,
                calendarService: calendarService
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(configManager: configManager)
        }
    }
}
