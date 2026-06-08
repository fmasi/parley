import SwiftUI
import AppKit
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
    @State private var xpcRetryCount = 0
    @State private var selectedMicId: String?

    init(
        appState: AppState,
        captureClient: AudioCaptureClient,
        transcriptionRunner: TranscriptionRunner,
        configManager: ConfigManager,
        calendarService: CalendarService
    ) {
        self.appState = appState
        self.captureClient = captureClient
        self.transcriptionRunner = transcriptionRunner
        self.configManager = configManager
        self.calendarService = calendarService
        self._selectedMicId = State(initialValue: configManager.config.lastMicrophoneDeviceId)
    }

    var body: some View {
        if let critical = appState.criticalError {
            Button("🔴 \(critical)") {}
                .disabled(true)
            Button("Acknowledge") {
                appState.criticalError = nil
            }
            Divider()
        }

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

        Button("About Audio Transcribe") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(options: [
                .version: AppVersion.displayString,
                .applicationVersion: "",
                .credits: aboutCredits,
            ])
        }

        Button("Quit") {
            LaunchAgentManager.uninstall()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Author + attribution shown in the standard macOS About panel.
    private var aboutCredits: NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center

        func text(_ string: String, size: CGFloat, color: NSColor, bold: Bool = false) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [
                .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                .foregroundColor: color,
                .paragraphStyle: center,
            ])
        }
        func link(_ label: String, _ url: String) -> NSAttributedString {
            NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: URL(string: url)!,
                .paragraphStyle: center,
            ])
        }

        let credits = NSMutableAttributedString()
        credits.append(text("Built by Frédéric Masi\n", size: 12, color: .labelColor, bold: true))
        credits.append(text("Private, on-device meeting transcription.\n\n", size: 11, color: .secondaryLabelColor))
        credits.append(link("LinkedIn", "https://www.linkedin.com/in/fmasi/"))
        credits.append(text("    ·    ", size: 11, color: .secondaryLabelColor))
        credits.append(link("GitHub", "https://github.com/fmasi/parley"))
        credits.append(text("\n\n© 2026 Frédéric Masi · AGPL-3.0", size: 10, color: .tertiaryLabelColor))
        return credits
    }

    private func toggleRecording() async {
        if appState.isRecording {
            await stopRecording()
        } else if appState.isIdle {
            promptAndStartRecording()
        }
    }

    private func promptAndStartRecording() {
        let suggestedName = calendarService.currentEventTitle(
            lookaheadMinutes: configManager.config.calendarLookaheadMinutes
        )
        SessionNameWindowController.shared.show(
            suggestedName: suggestedName,
            lastMicrophoneDeviceId: selectedMicId
        ) { sessionName, micDeviceId in
            selectedMicId = micDeviceId
            Task { await startRecording(sessionName: sessionName, microphoneDeviceId: micDeviceId) }
        }
    }

    private func startRecording(sessionName: String, microphoneDeviceId: String?) async {
        Logger.state.info("Recording started — session: \(sessionName, privacy: .public)")
        appState.errorMessage = nil

        let config = configManager.config
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dayDir = dateFormatter.string(from: Date())

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmmss"
        let timestamp = timeFormatter.string(from: Date())

        let sanitized = sanitizeFilename(sessionName)
        let chunkBaseName = sanitized.isEmpty ? timestamp : "\(timestamp)-\(sanitized)"
        let baseName = "\(chunkBaseName)-0"  // 0-indexed for chunk discovery

        let outputDir = URL(fileURLWithPath: config.recordingDirectory)
            .appendingPathComponent(dayDir)

        captureClient.onServiceCrash = { [appState, captureClient] in
            Task { @MainActor in
                guard appState.isRecording else { return }
                await self.handleXPCCrash(appState: appState, captureClient: captureClient)
            }
        }

        do {
            let sentinel = RecordingSentinel(
                startedAt: Date(),
                sessionName: sanitized.isEmpty ? "Recording" : sessionName,
                systemAudioPath: outputDir.appendingPathComponent(baseName + ".wav").path,
                micAudioPath: outputDir.appendingPathComponent(baseName + "_mic.wav").path,
                micDeviceUID: microphoneDeviceId,
                segment: 1,
                chunkIndex: 0
            )
            try RecordingSentinel.write(sentinel)

            try await captureClient.start(
                outputDirectory: outputDir,
                baseName: baseName,
                microphoneDeviceId: microphoneDeviceId
            )

            try transcriptionRunner.setupChunkedPipeline(
                captureClient: captureClient,
                outputDirectory: outputDir,
                sessionBaseName: chunkBaseName,
                config: config
            )
            transcriptionRunner.startChunkRotation()

            appState.phase = .recording(since: Date())
            xpcRetryCount = 0
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

            transcriptionRunner.stopChunkRotation()
            appState.phase = .transcribing(progress: "Transcribing...")

            if let rotator = transcriptionRunner.chunkRotator,
               let processor = transcriptionRunner.chunkProcessor {
                // Process the last chunk via the chunked pipeline
                let lastChunk = ChunkRotator.FinalizedChunk(
                    index: rotator.currentChunkInfo.index,
                    systemPath: paths.systemAudio.path,
                    micPath: paths.micAudio.path,
                    startTime: rotator.currentChunkInfo.startTime
                )
                await processor.processLastChunk(lastChunk)

                // Wait for any background chunks still processing
                await processor.awaitAllProcessed()

                // Final merge
                let sessionState = await processor.getSessionState()
                let outputDir = paths.systemAudio.deletingLastPathComponent()
                let result = try await transcriptionRunner.finalize(
                    sessionState: sessionState,
                    outputDirectory: outputDir,
                    config: configManager.config
                )

                appState.lastJsonPath = result.jsonPath.path
                appState.lastTranscriptPath = result.jsonPath.path
                appState.phase = .idle
                sendNotification(title: "Transcription Complete", body: result.jsonPath.lastPathComponent)
                let jsonPath = result.jsonPath
                let config = configManager.config
                RenameWindowController.shared.show(jsonPath: jsonPath) {
                    // Auto-summarize after rename completes (so summary has real speaker names)
                    Task.detached(priority: .utility) {
                        await MeetingSummarizer.summarizeIfConfigured(transcriptPath: jsonPath, config: config)
                    }
                }
            } else {
                // Fallback: no chunked pipeline (e.g. crash recovery path)
                let systemAudio: URL
                let micAudio: URL?
                if let sentinel, sentinel.segment > 1 {
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
                let jsonPath = result.jsonPath
                let config = configManager.config
                RenameWindowController.shared.show(jsonPath: jsonPath) {
                    Task.detached(priority: .utility) {
                        await MeetingSummarizer.summarizeIfConfigured(transcriptPath: jsonPath, config: config)
                    }
                }
            }

            transcriptionRunner.teardownChunkedPipeline()
        } catch {
            RecordingSentinel.delete()
            transcriptionRunner.teardownChunkedPipeline()
            appState.errorMessage = error.localizedDescription
            sendNotification(title: "Transcription Failed", body: error.localizedDescription)
            appState.phase = .idle
        }
    }

    private func handleXPCCrash(appState: AppState, captureClient: AudioCaptureClient) async {
        xpcRetryCount += 1
        Logger.state.warning("XPC crash during recording — attempt \(xpcRetryCount) of 2")

        guard let sentinel = RecordingSentinel.read() else {
            Logger.state.error("No sentinel found during crash recovery")
            appState.criticalError = "Recording failed — no recovery data available."
            appState.phase = .idle
            sendCriticalNotification(
                title: "Recording Failed",
                body: "Microphone capture crashed. No recovery data found."
            )
            return
        }

        // Retry limit: give up after 2 crashes
        if xpcRetryCount > 2 {
            Logger.state.error("All retries exhausted after \(xpcRetryCount) crashes")
            appState.criticalError = "Recording failed — microphone capture crashed repeatedly."
            appState.phase = .idle
            RecordingSentinel.delete()
            sendCriticalNotification(
                title: "Recording Failed",
                body: "Microphone capture crashed after retry. Your recording may be incomplete."
            )
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
            Logger.state.error("Restart failed: \(error, privacy: .public)")
            appState.criticalError = "Recording failed — could not restart capture: \(error.localizedDescription)"
            appState.phase = .idle
            RecordingSentinel.delete()
            sendCriticalNotification(
                title: "Recording Failed",
                body: "Microphone capture crashed and could not restart."
            )
        }
    }

    private var activeMicName: String {
        AudioDeviceEnumerator.availableDevices()
            .first(where: { $0.id == selectedMicId })?.name
            ?? "System Default"
    }

    private func openMicPicker() {
        if appState.isRecording {
            MicSwitchWindowController.shared.show(
                currentDeviceId: selectedMicId,
                buttonLabel: "Switch"
            ) { newDeviceId in
                try await captureClient.updateMicrophone(deviceId: newDeviceId)
                await MainActor.run {
                    selectedMicId = newDeviceId
                }
            }
        } else {
            MicSwitchWindowController.shared.show(
                currentDeviceId: selectedMicId,
                buttonLabel: "Switch"
            ) { newDeviceId in
                await MainActor.run {
                    selectedMicId = newDeviceId
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

    private func sendCriticalNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        Logger.state.error("CRITICAL: \(title, privacy: .public) — \(body, privacy: .public)")

        // Floating panel — impossible to miss, no entitlement needed
        CriticalAlertController.shared.show(title: title, message: body) {
            // onDismiss syncs with menu bar icon acknowledgment
        }

        // Also send notification for the record (may land in Notification Center)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .defaultCritical
        content.interruptionLevel = .critical
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger.state.error("Critical notification failed: \(error, privacy: .public)")
            }
        }
    }
}
