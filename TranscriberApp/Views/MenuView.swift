import SwiftUI
import SettingsAccess
import TranscriberCore
import UserNotifications

struct MenuView: View {
    @Bindable var appState: AppState
    let captureClient: AudioCaptureClient
    let transcriptionRunner: TranscriptionRunner
    let configManager: ConfigManager
    let calendarService: CalendarService

    var body: some View {
        Button(appState.recordingToggleLabel) {
            Task { await toggleRecording() }
        }
        .disabled(appState.isTranscribing)

        Divider()

        Button("Open Recordings Folder") {
            let dir = URL(fileURLWithPath: configManager.config.recordingDirectory)
            NSWorkspace.shared.open(dir)
        }

        Button("Rename Speakers...") {
            if let jsonPath = appState.lastJsonPath {
                RenameWindowController.shared.show(jsonPath: URL(fileURLWithPath: jsonPath))
            }
        }
        .disabled(!appState.isIdle || appState.lastJsonPath == nil)

        SettingsLink {
            Text("Settings...")
        } preAction: {
        } postAction: {
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func toggleRecording() async {
        if appState.isRecording {
            await stopRecording()
        } else if appState.isIdle {
            promptAndStartRecording()
        }
    }

    private func promptAndStartRecording() {
        let suggestedName = calendarService.currentEventTitle()
        let lastMicId = configManager.config.lastMicrophoneDeviceId
        SessionNameWindowController.shared.show(
            suggestedName: suggestedName,
            lastMicrophoneDeviceId: lastMicId
        ) { sessionName, micDeviceId in
            Task { await startRecording(sessionName: sessionName, microphoneDeviceId: micDeviceId) }
        }
    }

    private func startRecording(sessionName: String, microphoneDeviceId: String?) async {
        // Persist the mic choice for next time
        configManager.update { $0.lastMicrophoneDeviceId = microphoneDeviceId }

        let config = configManager.config
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dayDir = dateFormatter.string(from: Date())

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmmss"
        let timestamp = timeFormatter.string(from: Date())

        let sanitized = sanitizeFilename(sessionName)
        let baseName = sanitized.isEmpty ? timestamp : "\(timestamp)-\(sanitized)"

        let outputDir = URL(fileURLWithPath: config.recordingDirectory)
            .appendingPathComponent(dayDir)

        do {
            try await captureClient.start(
                outputDirectory: outputDir,
                baseName: baseName,
                microphoneDeviceId: microphoneDeviceId
            )
            appState.phase = .recording(since: Date())
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func stopRecording() async {
        do {
            let paths = try await captureClient.stop()
            appState.phase = .transcribing(progress: "Transcribing...")

            let config = configManager.config
            let result = try await transcriptionRunner.run(
                systemAudio: paths.systemAudio,
                micAudio: paths.micAudio,
                outputFormat: config.outputFormat,
                outputDirectory: paths.systemAudio.deletingLastPathComponent(),
                hfToken: config.hfToken
            )

            appState.lastTranscriptPath = result.outputPath.path
            appState.lastJsonPath = result.jsonPath?.path
            appState.phase = .idle
            sendNotification(path: result.outputPath)

            if let jsonPath = result.jsonPath {
                RenameWindowController.shared.show(jsonPath: jsonPath)
            }
        } catch {
            appState.errorMessage = error.localizedDescription
            appState.phase = .idle
        }
    }

    private func sendNotification(path: URL) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Transcription Complete"
        content.body = path.lastPathComponent
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
