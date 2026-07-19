import SwiftUI
import AppKit
import SettingsAccess
import TranscriberCore
import UniformTypeIdentifiers
import UserNotifications
import Sparkle
import os

struct MenuView: View {
    @Bindable var appState: AppState
    let captureClient: AudioCaptureClient
    let transcriptionRunner: TranscriptionRunner
    let configManager: ConfigManager
    let calendarService: CalendarService
    let updater: SPUUpdater
    @State private var selectedMicId: String?
    /// Owns the recording lifecycle + crash recovery (moved out of this view, #139 PR-6).
    /// `@State`-held so it has exactly the lifetime the old `@State` counters had.
    @State private var coordinator: RecordingCoordinator
    /// Closes the window-style MenuBarExtra panel (macOS 14+ honors dismiss here).
    @Environment(\.dismiss) private var dismissPanel

    init(
        appState: AppState,
        captureClient: AudioCaptureClient,
        transcriptionRunner: TranscriptionRunner,
        configManager: ConfigManager,
        calendarService: CalendarService,
        updater: SPUUpdater
    ) {
        self.appState = appState
        self.captureClient = captureClient
        self.transcriptionRunner = transcriptionRunner
        self.configManager = configManager
        self.calendarService = calendarService
        self.updater = updater
        self._selectedMicId = State(initialValue: configManager.config.lastMicrophoneDeviceId)
        // The coordinator owns orchestration; the app-target UI side effects it needs
        // (notifications, the critical panel, the rename dialog + auto-summary) are injected here.
        self._coordinator = State(initialValue: RecordingCoordinator(
            appState: appState,
            captureClient: captureClient,
            transcriptionRunner: transcriptionRunner,
            configManager: configManager,
            notify: { title, body in
                MenuView.postNotification(title: title, body: body)
            },
            notifyCritical: { title, body in
                MenuView.sendCriticalNotification(title: title, body: body)
            },
            presentTranscript: { jsonPath, config in
                RenameWindowController.shared.show(jsonPath: jsonPath) {
                    // Auto-summarize after rename completes (so summary has real speaker names)
                    MenuView.autoSummarize(jsonPath: jsonPath, config: config)
                }
            }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHeader

            if appState.criticalError != nil || appState.interruptionWarning != nil
                || appState.truncatedErrorMessage != nil {
                alertBanners
            }

            recordButton

            MenuActionRow(icon: "mic", title: activeMicName, subtitle: "Microphone") {
                dismissPanel()
                openMicPicker()
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                MenuActionRow(icon: "folder", title: "Open Recordings Folder") {
                    dismissPanel()
                    let dir = URL(fileURLWithPath: configManager.config.recordingDirectory)
                    NSWorkspace.shared.open(dir)
                }

                MenuActionRow(
                    icon: "person.2",
                    title: "Rename Speakers…",
                    // Only gated on being idle. It used to also require `lastJsonPath`, which is set
                    // only by a transcription in THIS app session — so after any quit or crash the
                    // item was permanently greyed out and a recording could never be renamed again.
                    // Speaker labels are the thing users most need to correct; there must always be
                    // a way in. With no recent transcript we ask which one.
                    isDisabled: !appState.isIdle
                ) {
                    dismissPanel()
                    if let jsonPath = appState.lastJsonPath,
                       FileManager.default.fileExists(atPath: jsonPath) {
                        RenameWindowController.shared.show(jsonPath: URL(fileURLWithPath: jsonPath))
                    } else if let picked = pickTranscript() {
                        RenameWindowController.shared.show(jsonPath: picked)
                    }
                }

                SettingsLink {
                    MenuRowLabel(icon: "gearshape", title: "Settings…")
                } preAction: {
                    dismissPanel()
                } postAction: {
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)

                CheckForUpdatesView(updater: updater)
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                MenuActionRow(icon: "info.circle", title: "About Parley") {
                    dismissPanel()
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .version: AppVersion.displayString,
                        .applicationVersion: "",
                        .credits: aboutCredits,
                    ])
                }

                MenuActionRow(icon: "power", title: "Quit Parley") {
                    LaunchAgentManager.uninstall()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    // MARK: - Panel sections

    /// App name + live state. The one animated element: a pulsing dot and a
    /// ticking timer while recording; a small spinner while transcribing.
    private var statusHeader: some View {
        HStack(spacing: 10) {
            StatusDot(color: statusColor, pulsing: appState.isRecording)
            VStack(alignment: .leading, spacing: 1) {
                Text("Parley")
                    .font(.headline)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if case .recording(let since) = appState.phase {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(recordingTimerString(from: since, to: context.date))
                        .font(.title3.monospacedDigit())
                        .fontDesign(.rounded)
                        .foregroundStyle(.red)
                }
            } else if appState.isTranscribing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var statusColor: Color {
        if appState.criticalError != nil { return .red }
        switch appState.phase {
        case .idle: return .green
        case .recording: return .red
        case .transcribing: return .orange
        }
    }

    private var statusText: String {
        // Must guard on criticalError for the same reason statusColor does:
        // after a crash the phase falls back to .idle, which would otherwise
        // pair a red dot with "Ready to record". The banner carries the detail.
        if appState.criticalError != nil { return "Error" }
        switch appState.phase {
        case .idle: return "Ready to record"
        case .recording: return appState.interruptionWarning == nil ? "Recording" : "Recording — interrupted"
        case .transcribing(let progress): return progress
        }
    }

    @ViewBuilder
    private var alertBanners: some View {
        if let critical = appState.criticalError {
            AlertBanner(severity: .critical, message: critical) {
                appState.criticalError = nil
            }
        }
        if let warning = appState.interruptionWarning {
            AlertBanner(severity: .warning, message: warning) {
                appState.interruptionWarning = nil
            }
        }
        if let errorText = appState.truncatedErrorMessage {
            AlertBanner(severity: .warning, message: errorText) {
                Logger.state.debug("User dismissed error")
                appState.errorMessage = nil
            }
        }
    }

    /// The primary action. Red is reserved for exactly this (and criticals).
    private var recordButton: some View {
        Button {
            // Starting opens the session-name panel — close this one first so
            // they don't stack. Stopping keeps the panel up: the header flips
            // to "Transcribing…" as live feedback.
            if appState.isIdle { dismissPanel() }
            Task { await toggleRecording() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: appState.isRecording ? "stop.fill" : "record.circle")
                Text(recordButtonTitle)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)
        .disabled(appState.isTranscribing)
    }

    private var recordButtonTitle: String {
        switch appState.phase {
        case .idle: return "Start Recording"
        case .recording: return "Stop Recording"
        case .transcribing: return "Transcribing…"
        }
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

    /// Ask which transcript to rename. Used when this app session hasn't produced one (a relaunch,
    /// or renaming an older recording) — otherwise a recording could never be renamed after a quit.
    private func pickTranscript() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a transcript"
        panel.message = "Select the transcript (.json) whose speakers you want to rename."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: configManager.config.recordingDirectory)
        NSApp.activate()  // macOS 14+ replacement for the deprecated ignoringOtherApps: form
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func toggleRecording() async {
        if appState.isRecording {
            await coordinator.stopRecording()
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
            let coordinator = coordinator
            Task { await coordinator.startRecording(sessionName: sessionName, microphoneDeviceId: micDeviceId) }
        }
    }

    // startRecording / stopRecording / handleXPCCrash / finalizeAbandonedSession moved to
    // TranscriberCore/RecordingCoordinator.swift (#139 PR-6) so the recording lifecycle and
    // crash-recovery state machines are unit-testable outside this SwiftUI view.

    private var activeMicName: String {
        // Prefer the helper-reported device (post auto-switch) over the user's configured preference.
        // `helperMicKnown` is false until the helper reports back; when true, `helperMicId` wins
        // (nil = system default, non-nil = specific device). The coordinator owns both flags now.
        let id: String? = coordinator.helperMicKnown ? coordinator.helperMicId : selectedMicId
        return AudioDeviceEnumerator.availableDevices()
            .first(where: { $0.id == id })?.name
            ?? "System Default"
    }

    private func openMicPicker() {
        // Mid-recording the switch is applied to the live capture; when idle it only updates the
        // remembered selection. Everything else about the two cases is identical, so decide once
        // here (at show time, as before) instead of duplicating the whole call.
        let isRecording = appState.isRecording
        MicSwitchWindowController.shared.show(
            currentDeviceId: selectedMicId,
            buttonLabel: "Switch"
        ) { newDeviceId in
            if isRecording {
                try await captureClient.updateMicrophone(deviceId: newDeviceId)
            }
            await MainActor.run {
                selectedMicId = newDeviceId
            }
        }
    }

    /// Run the auto-summary off the main actor and, if it fails, surface the reason as a
    /// notification instead of failing silently (#134). Static + self-free so it is safe to
    /// fire from a rename-dialog completion without capturing the view.
    static func autoSummarize(jsonPath: URL, config: Config) {
        Task.detached(priority: .utility) {
            if case .failed(let message) = await MeetingSummarizer.summarizeIfConfigured(
                transcriptPath: jsonPath, config: config) {
                postNotification(title: "Summary Failed", body: message)
            }
        }
    }

    /// Post a user notification (time-sensitive by default; criticals pass their own sound and
    /// interruption level). `nonisolated` + self-free so it is safe to call from a detached
    /// (`@Sendable`) task off the main actor — e.g. reporting a failed background auto-summary
    /// (#134). `UNUserNotificationCenter` is thread-safe, so no main-actor hop is needed.
    nonisolated static func postNotification(
        title: String,
        body: String,
        sound: UNNotificationSound = .default,
        interruptionLevel: UNNotificationInterruptionLevel = .timeSensitive
    ) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        Logger.state.debug("Sending notification: \(title, privacy: .public)")
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        content.interruptionLevel = interruptionLevel
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger.state.error("Notification failed: \(error, privacy: .public)")
            }
        }
    }

    static func sendCriticalNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        Logger.state.error("CRITICAL: \(title, privacy: .public) — \(body, privacy: .public)")

        // Floating panel — impossible to miss, no entitlement needed
        CriticalAlertController.shared.show(title: title, message: body) {
            // onDismiss syncs with menu bar icon acknowledgment
        }

        // Also send notification for the record (may land in Notification Center) — same body as
        // postNotification, just with the critical sound + interruption level.
        postNotification(title: title, body: body, sound: .defaultCritical, interruptionLevel: .critical)
    }
}
