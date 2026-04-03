import SwiftUI
import SettingsAccess
import TranscriberCore
import UserNotifications
import os

struct MenuView: View {
    @Bindable var appState: AppState
    let captureClient: AudioCaptureClient
    let transcriptionRunner: TranscriptionRunner
    let configManager: ConfigManager
    let calendarService: CalendarService

    @State private var cachedDevices: [AudioInputDevice] = AudioDeviceEnumerator.availableDevices()

    var body: some View {
        if let warning = appState.interruptionWarning {
            Button("⚠ \(warning)") {}
                .disabled(true)
            Button("Dismiss") {
                appState.interruptionWarning = nil
            }
            Divider()
        }

        if let errorText = appState.truncatedErrorMessage {
            Button("⚠ Error: \(errorText)") {}
                .disabled(true)
            Button("Dismiss Error") {
                Logger.state.debug("User dismissed error")
                appState.errorMessage = nil
            }
            Divider()
        }

        Button(appState.recordingToggleLabel) {
            Task { await toggleRecording() }
        }
        .disabled(appState.isTranscribing)

        Button { openMicPicker() } label: {
            Label(activeMicName, systemImage: "mic")
        }

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
            LaunchAgentManager.uninstall()
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
        Logger.state.info("Recording started — session: \(sessionName, privacy: .public)")
        appState.errorMessage = nil

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

        captureClient.onServiceCrash = { [appState, captureClient] in
            Task { @MainActor in
                guard appState.isRecording else { return }
                await self.handleXPCCrash(appState: appState, captureClient: captureClient)
            }
        }

        do {
            try await captureClient.start(
                outputDirectory: outputDir,
                baseName: baseName,
                microphoneDeviceId: microphoneDeviceId
            )

            let sentinel = RecordingSentinel(
                startedAt: Date(),
                sessionName: sanitized.isEmpty ? "Recording" : sessionName,
                systemAudioPath: outputDir.appendingPathComponent(baseName + ".wav").path,
                micAudioPath: outputDir.appendingPathComponent(baseName + "_mic.wav").path,
                micDeviceUID: microphoneDeviceId,
                segment: 1
            )
            try RecordingSentinel.write(sentinel)

            appState.phase = .recording(since: Date())
        } catch {
            RecordingSentinel.delete()
            appState.errorMessage = error.localizedDescription
            sendNotification(title: "Recording Failed", body: error.localizedDescription)
        }
    }

    private func stopRecording() async {
        Logger.state.info("Recording stopped")
        do {
            let sentinel = RecordingSentinel.read()
            let paths = try await captureClient.stop()
            RecordingSentinel.delete()
            appState.phase = .transcribing(progress: "Transcribing...")

            // Use original segment-1 paths for multi-segment discovery
            let systemAudio: URL
            let micAudio: URL?
            if let sentinel, sentinel.segment > 1 {
                // Get the original base name (strip segment suffix)
                let origBase = stripSegmentSuffix(sentinel.systemAudioPath)
                let dir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
                systemAudio = dir.appendingPathComponent(origBase + ".wav")
                micAudio = dir.appendingPathComponent(origBase + "_mic.wav")
            } else {
                systemAudio = paths.systemAudio
                micAudio = paths.micAudio
            }

            let result = try await transcriptionRunner.run(
                systemAudio: systemAudio,
                micAudio: micAudio,
                outputDirectory: systemAudio.deletingLastPathComponent(),
                config: configManager.config
            )

            appState.lastJsonPath = result.jsonPath.path
            appState.lastTranscriptPath = result.jsonPath.path
            appState.phase = .idle
            sendNotification(title: "Transcription Complete", body: result.jsonPath.lastPathComponent)

            RenameWindowController.shared.show(jsonPath: result.jsonPath)
        } catch {
            RecordingSentinel.delete()
            appState.errorMessage = error.localizedDescription
            sendNotification(title: "Transcription Failed", body: error.localizedDescription)
            appState.phase = .idle
        }
    }

    private func handleXPCCrash(appState: AppState, captureClient: AudioCaptureClient) async {
        Logger.state.warning("XPC service crashed during recording — restarting capture")

        guard let sentinel = RecordingSentinel.read() else {
            Logger.state.error("No sentinel found during crash recovery")
            appState.errorMessage = "Recording interrupted — no recovery data"
            appState.phase = .idle
            return
        }

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
            sendNotification(
                title: "Recording Resumed",
                body: "Recording was briefly interrupted and has been restarted."
            )
        } catch {
            Logger.state.error("Failed to restart capture after XPC crash: \(error, privacy: .public)")
            appState.errorMessage = "Recording lost — failed to restart: \(error.localizedDescription)"
            appState.phase = .idle
            RecordingSentinel.delete()
        }
    }

    private var activeMicName: String {
        cachedDevices
            .first(where: { $0.id == configManager.config.lastMicrophoneDeviceId })?.name
            ?? "System Default"
    }

    private func openMicPicker() {
        if appState.isRecording {
            MicSwitchWindowController.shared.show(
                currentDeviceId: configManager.config.lastMicrophoneDeviceId,
                buttonLabel: "Switch"
            ) { newDeviceId in
                try await captureClient.updateMicrophone(deviceId: newDeviceId)
                await MainActor.run {
                    configManager.update { $0.lastMicrophoneDeviceId = newDeviceId }
                }
            }
        } else {
            MicSwitchWindowController.shared.show(
                currentDeviceId: configManager.config.lastMicrophoneDeviceId,
                buttonLabel: "Set Default"
            ) { newDeviceId in
                await MainActor.run {
                    configManager.update { $0.lastMicrophoneDeviceId = newDeviceId }
                }
            }
        }
    }

    private func sendNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        Logger.state.debug("Sending notification: \(title, privacy: .public)")
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger.state.error("Notification failed: \(error, privacy: .public)")
            }
        }
    }
}
