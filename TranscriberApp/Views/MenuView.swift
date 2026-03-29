import SwiftUI
import SettingsAccess
import UserNotifications

struct MenuView: View {
    @Bindable var appState: AppState
    let captureClient: AudioCaptureClient
    let transcriptionRunner: TranscriptionRunner
    let configManager: ConfigManager

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
            appState.showRenameSheet = true
        }
        .disabled(!appState.isIdle)

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
            await startRecording()
        }
    }

    private func startRecording() async {
        let config = configManager.config
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dayDir = dateFormatter.string(from: Date())

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmmss"
        let baseName = timeFormatter.string(from: Date())

        let outputDir = URL(fileURLWithPath: config.recordingDirectory)
            .appendingPathComponent(dayDir)

        do {
            try await captureClient.start(
                outputDirectory: outputDir,
                baseName: baseName
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
                outputDirectory: paths.systemAudio.deletingLastPathComponent()
            )

            appState.lastTranscriptPath = result.outputPath.path
            appState.phase = .idle
            sendNotification(path: result.outputPath)
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
