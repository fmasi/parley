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
    @State private var lastCrashAt: Date?
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

        Button("About Parley") {
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
        // #86: a benign route change no longer reads as a crash. The helper restarts the stream in
        // place (onRestartInPlace) or the connection blips without a crash report (onBriefInterruption)
        // — both keep recording and just surface a transient notice. Only a fatal give-up escalates.
        captureClient.onRestartInPlace = { [appState] in
            Task { @MainActor in
                guard appState.isRecording else { return }
                appState.interruptionWarning = "Audio device changed — recording resumed automatically."
            }
        }
        captureClient.onBriefInterruption = { [appState] in
            Task { @MainActor in
                guard appState.isRecording else { return }
                appState.interruptionWarning = "Recording briefly interrupted — continuing."
            }
        }
        captureClient.onFatalFailure = { [appState, captureClient] _ in
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
            lastCrashAt = nil
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
                var sessionState = await processor.getSessionState()
                let outputDir = paths.systemAudio.deletingLastPathComponent()
                // Drain capture diagnostics, flush <session>.diag.jsonl only if anomalous, and stamp
                // the always-present provenance into the transcript metadata (#95).
                sessionState.provenance = await captureClient.finalizeSessionDiagnostics(
                    sessionId: sessionState.sessionId,
                    engine: configManager.config.engine.rawValue,
                    recordingDirectory: outputDir
                )
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
                    // #7: point discovery at the 0-indexed base so SegmentDiscovery's gap-tolerant
                    // 0-indexed mode reclaims every segment (-0, -1, …). The stripped base would use
                    // legacy mode and drop the -0 orphan, referencing a non-existent <root>.wav.
                    let origBase = stripSegmentSuffix(sentinel.systemAudioPath)
                    let dir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
                    systemAudio = dir.appendingPathComponent(origBase + "-0.wav")
                    micAudio = dir.appendingPathComponent(origBase + "-0_mic.wav")
                } else {
                    systemAudio = paths.systemAudio
                    micAudio = paths.micAudio
                }

                // #95/council F6: the recovery path also drains diagnostics, flushes the
                // anomaly-gated <sessionId>.diag.jsonl, and stamps capture_provenance (incl.
                // recovered=true) — previously only the chunked branch did this.
                let outputDir = systemAudio.deletingLastPathComponent()
                let sessionId = systemAudio.deletingPathExtension().lastPathComponent
                let provenance = await captureClient.finalizeSessionDiagnostics(
                    sessionId: sessionId,
                    engine: configManager.config.engine.rawValue,
                    recordingDirectory: outputDir
                )

                let result = try await transcriptionRunner.run(
                    systemAudio: systemAudio,
                    micAudio: micAudio,
                    outputDirectory: outputDir,
                    config: configManager.config,
                    provenance: provenance
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
        // #61: count consecutive failures with time decay, not a cumulative lifetime cap, so a long
        // recording isn't locked out by sporadic, individually-recovered interruptions. A tight
        // crash loop (interruptions within the decay window) still trips the cap.
        let decision = XPCRetryPolicy.register(
            priorCount: xpcRetryCount, lastCrashAt: lastCrashAt, now: Date()
        )
        xpcRetryCount = decision.retryCount
        lastCrashAt = Date()
        captureClient.recordRetry(["attempt": "\(xpcRetryCount)", "giveUp": "\(decision.shouldGiveUp)"])
        Logger.state.warning("XPC interruption during recording — attempt \(xpcRetryCount) within the decay window")

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

        if decision.shouldGiveUp {
            Logger.state.error("All retries exhausted after \(xpcRetryCount) interruptions within the decay window")
            // council F3: salvage the live chunked session (re-ingesting the in-progress orphan,
            // since this branch returns before the normal re-ingestion below) so chunks already
            // transcribed aren't discarded with the session.
            await finalizeAbandonedSession(
                sentinel: sentinel, reingestOrphan: true, appState: appState, captureClient: captureClient
            )
            appState.criticalError = "Recording failed — microphone capture crashed repeatedly. Audio recorded before the failure has been saved."
            appState.phase = .idle
            RecordingSentinel.delete()
            sendCriticalNotification(
                title: "Recording Failed",
                body: "Microphone capture crashed after retry. The portion recorded before the failure has been transcribed."
            )
            return
        }

        let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        let baseName: String
        var newSentinel: RecordingSentinel

        // #92: when the chunked pipeline is still live (the common live-crash case), re-ingest the
        // orphaned in-progress chunk and advance the rotator BEFORE restarting capture. Otherwise
        // the orphan's audio is processed by no one and silently dropped from the final transcript.
        if let rotator = transcriptionRunner.chunkRotator,
           let processor = transcriptionRunner.chunkProcessor {
            let orphan = rotator.currentChunkInfo
            let orphanBase = rotator.currentBaseName  // live-index base, NOT the stale sentinel path
            processor.processChunk(ChunkRotator.FinalizedChunk(
                index: orphan.index,
                systemPath: outputDir.appendingPathComponent(orphanBase + ".wav").path,
                micPath: outputDir.appendingPathComponent(orphanBase + "_mic.wav").path,
                startTime: orphan.startTime
            ))
            let plan = rotator.recoverFromCrash()
            baseName = plan.recoveryBaseName
            newSentinel = sentinel.incrementedSegment(
                systemAudioPath: outputDir.appendingPathComponent(baseName + ".wav").path,
                micAudioPath: outputDir.appendingPathComponent(baseName + "_mic.wav").path
            )
            newSentinel.chunkIndex = plan.recoveryIndex
            Logger.state.info("Re-ingested orphan chunk \(orphan.index, privacy: .public) (\(orphanBase, privacy: .public)); recovery continues at \(baseName, privacy: .public)")
        } else {
            // No live pipeline (app-relaunch re-attach): keep segment-based naming; the stop-path
            // fallback uses 0-indexed gap-tolerant discovery to reclaim every segment.
            let seg = sentinel.segment + 1
            baseName = segmentBaseName(originalPath: sentinel.systemAudioPath, segment: seg)
            newSentinel = sentinel.incrementedSegment(
                systemAudioPath: outputDir.appendingPathComponent(baseName + ".wav").path,
                micAudioPath: outputDir.appendingPathComponent(baseName + "_mic.wav").path
            )
        }

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
            // council F3: the orphan was already re-ingested above, so just finalize what's been
            // processed rather than abandoning the whole session.
            await finalizeAbandonedSession(
                sentinel: sentinel, reingestOrphan: false, appState: appState, captureClient: captureClient
            )
            appState.criticalError = "Recording failed — could not restart capture: \(error.localizedDescription). Audio recorded before the failure has been saved."
            appState.phase = .idle
            RecordingSentinel.delete()
            sendCriticalNotification(
                title: "Recording Failed",
                body: "Microphone capture crashed and could not restart. The portion recorded before the failure has been transcribed."
            )
        }
    }

    /// Best-effort finalize a live chunked session being abandoned after an unrecoverable crash, so
    /// chunks already transcribed to session.json become a real transcript instead of being silently
    /// discarded (council F3). The give-up branch returns before the normal orphan re-ingestion, so
    /// it passes reingestOrphan: true to reclaim the in-progress chunk first.
    private func finalizeAbandonedSession(
        sentinel: RecordingSentinel,
        reingestOrphan: Bool,
        appState: AppState,
        captureClient: AudioCaptureClient
    ) async {
        guard let processor = transcriptionRunner.chunkProcessor else { return }
        let outputDir = URL(fileURLWithPath: sentinel.systemAudioPath).deletingLastPathComponent()
        transcriptionRunner.stopChunkRotation()

        if reingestOrphan, let rotator = transcriptionRunner.chunkRotator {
            let orphan = rotator.currentChunkInfo
            let orphanBase = rotator.currentBaseName
            processor.processChunk(ChunkRotator.FinalizedChunk(
                index: orphan.index,
                systemPath: outputDir.appendingPathComponent(orphanBase + ".wav").path,
                micPath: outputDir.appendingPathComponent(orphanBase + "_mic.wav").path,
                startTime: orphan.startTime
            ))
        }

        await processor.awaitAllProcessed()
        var sessionState = await processor.getSessionState()
        guard !sessionState.chunks.isEmpty else {
            transcriptionRunner.teardownChunkedPipeline()
            return
        }
        sessionState.provenance = await captureClient.finalizeSessionDiagnostics(
            sessionId: sessionState.sessionId,
            engine: configManager.config.engine.rawValue,
            recordingDirectory: outputDir
        )
        if let result = try? await transcriptionRunner.finalize(
            sessionState: sessionState, outputDirectory: outputDir, config: configManager.config
        ) {
            appState.lastJsonPath = result.jsonPath.path
            appState.lastTranscriptPath = result.jsonPath.path
            Logger.state.info("Salvaged abandoned chunked session → \(result.jsonPath.lastPathComponent, privacy: .public)")
        }
        transcriptionRunner.teardownChunkedPipeline()
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
