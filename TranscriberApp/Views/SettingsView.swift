import SwiftUI
import AppKit
import ServiceManagement
import TranscriberCore

private enum DownloadState: Equatable {
    case idle
    case downloading(Double)
    case done
    case failed(String)
}

/// Settings, tabbed like a first-party app: General / Audio / Transcription /
/// Summary / Permissions. Apply semantics are unchanged — edits are local
/// @State until Save writes the config (instant-apply is a separate, careful
/// pass; see docs/design/ui-audit-0.8.x.md).
struct SettingsView: View {
    let configManager: ConfigManager
    @Bindable var permissionManager: PermissionManager
    @State private var config: Config
    @State private var saveStatus: String?
    @State private var downloadState: DownloadState = .idle
    @State private var downloadTask: Task<Void, Never>?
    @State private var archiveUsageBytes: Int = 0
    @State private var updateCheckInFlight = false
    @State private var lastUpdateStatus: String?
    private let manifestHealth = ManifestHealthStore.shared
    @State private var summaryEnabled: Bool = false
    @State private var summaryProvider: SummaryProviderType = .openai
    @State private var summaryEndpoint: String = ""
    @State private var summaryApiKey: String = ""
    @State private var summaryModel: String = "gpt-4o-mini"
    @State private var summaryContextLength: String = ""
    @State private var summaryContextOverheadPercent: String = ""
    @State private var summaryMaxOutputTokens: String = ""
    @State private var settingsMicId: String?
    @State private var settingsMicDevices: [AudioInputDevice] = []

    init(configManager: ConfigManager, permissionManager: PermissionManager) {
        self.configManager = configManager
        self.permissionManager = permissionManager
        self._config = State(initialValue: configManager.config)
        let s = configManager.config.summary
        self._summaryEnabled = State(initialValue: s?.enabled ?? false)
        self._summaryProvider = State(initialValue: s?.provider ?? .openai)
        self._summaryEndpoint = State(initialValue: s?.endpoint ?? "")
        self._summaryApiKey = State(initialValue: s?.apiKey ?? "")
        self._summaryModel = State(initialValue: s?.model ?? "gpt-4o-mini")
        self._summaryContextLength = State(initialValue: s?.contextLength.map(String.init) ?? "")
        self._summaryContextOverheadPercent = State(initialValue: s?.contextOverheadPercent.map(String.init) ?? "")
        self._summaryMaxOutputTokens = State(initialValue: s?.maxOutputTokens.map(String.init) ?? "")
        self._settingsMicId = State(initialValue: configManager.config.lastMicrophoneDeviceId)
    }

    private var isDownloading: Bool {
        if case .downloading = downloadState { return true }
        return false
    }

    /// The Summary tab grows with what it actually shows: one section when
    /// summaries are off (the common case), plus Provider, plus LM Studio's
    /// Context fields. A fixed tall frame left ~500pt of empty Form under the
    /// single toggle every new user sees first.
    private var summaryTabHeight: CGFloat {
        guard summaryEnabled else { return 260 }
        return summaryProvider == .lmstudio ? 620 : 460
    }

    var body: some View {
        TabView {
            tabPage(height: 420) { generalSections }
                .tabItem { Label("General", systemImage: "gearshape") }
            tabPage(height: 560) { audioSections }
                .tabItem { Label("Audio", systemImage: "waveform") }
            tabPage(height: 440) { transcriptionSections }
                .tabItem { Label("Transcription", systemImage: "text.quote") }
            tabPage(height: summaryTabHeight) { summarySections }
                .tabItem { Label("Summary", systemImage: "doc.text") }
            tabPage(height: 400) { permissionsSections }
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 500)
        // Enumerate eagerly, not on the Audio tab's onAppear: with a TabView
        // that would only fire once the user visits Audio, leaving the mic
        // picker empty until then.
        .onAppear { settingsMicDevices = AudioDeviceEnumerator.availableDevices() }
    }

    /// A tab's page: its form sections above the shared Save bar. Every tab
    /// carries the bar so pending edits can be saved from wherever they were
    /// made.
    private func tabPage<Content: View>(
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Form { content() }
                .formStyle(.grouped)
            Divider()
            saveBar
        }
        .frame(height: height)
    }

    private var saveBar: some View {
        HStack(spacing: 12) {
            if let status = saveStatus {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer()
            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(isDownloading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - General

    @ViewBuilder
    private var generalSections: some View {
        Section("Startup") {
            Toggle("Launch at Login", isOn: $config.launchOnStartup)
                .onChange(of: config.launchOnStartup) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        // Revert on failure
                        config.launchOnStartup = !enabled
                    }
                }
        }

        Section("Recordings") {
            LabeledContent {
                Button("Choose…") {
                    if let path = chooseFolderPath(message: "Choose where to save recordings") {
                        config.recordingDirectory = path
                    }
                }
                .controlSize(.small)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording Folder")
                    Text(abbreviatedDisplayPath(config.recordingDirectory))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Picker("Transcript Format", selection: $config.outputFormat) {
                Text("Plain Text (.txt)").tag("txt")
                Text("Subtitles (.srt)").tag("srt")
                Text("JSON (.json)").tag("json")
            }
        }

        Section("About") {
            LabeledContent("Version", value: AppVersion.displayString)
            LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–")
        }
    }

    // MARK: - Audio

    @ViewBuilder
    private var audioSections: some View {
        Section("Microphone") {
            MicrophonePicker(
                selectedDeviceId: $settingsMicId,
                devices: settingsMicDevices
            )
            Text("Sessions will start with this microphone unless changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("System Audio") {
            Picker("Capture Method", selection: $config.systemAudioSource) {
                Text("Screen Recording (default)").tag(SystemAudioSource.screenCaptureKit)
                Text("Core Audio Tap (captures calls)").tag(SystemAudioSource.coreAudioTap)
            }
            if config.systemAudioSource == .coreAudioTap {
                Text("Captures Continuity/phone & VoIP call audio that Screen Recording misses. Asks for System Audio Recording permission on first use. Applies to the next recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        // Silence detection has no consumer in the codebase (dead config key),
        // so it gets no UI. If the pipeline ever implements it, add the
        // section back here.

        Section("Audio Archive") {
            Picker("Archive Quality", selection: $config.archiveBitrateKbps) {
                Text("Compact (48 kbps)").tag(48)
                Text("Balanced (64 kbps)").tag(64)
                Text("High (96 kbps)").tag(96)
                Text("Maximum (128 kbps)").tag(128)
            }

            Stepper(
                "Keep last \(config.audioArchiveLimitHours) hours",
                value: $config.audioArchiveLimitHours,
                in: 1...999
            )

            let estimatedMiB = config.audioArchiveLimitHours * config.archiveBitrateKbps * 1000 / 8 * 3600 / 1_048_576
            let usageMiB = archiveUsageBytes / 1_048_576
            let usageHours = config.archiveBitrateKbps > 0
                ? archiveUsageBytes * 8 / (config.archiveBitrateKbps * 1000) / 3600
                : 0
            Text("≈ \(estimatedMiB) MiB at this quality. Currently using \(usageMiB) MiB (≈ \(usageHours) hours).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .task {
                    archiveUsageBytes = StorageManager.currentUsageBytes(
                        in: URL(fileURLWithPath: config.recordingDirectory)
                    )
                }
            Text("When over the limit, the oldest audio is deleted first. Transcripts are never deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transcription

    @ViewBuilder
    private var transcriptionSections: some View {
        Section("Engine") {
            Picker("Engine", selection: $config.engine) {
                ForEach(EngineID.availableEngines) { engine in
                    Text(engine.descriptor.displayName)
                        .tag(engine)
                }
            }
            .onChange(of: config.engine) { _, _ in
                downloadTask?.cancel()
                downloadTask = nil
                downloadState = .idle
            }

            if config.engine.descriptor.requiresModelDownload {
                engineModelStatus
            }
        }

        Section("Model Updates") {
            if let problem = manifestHealth.problemMessage {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle("Check for Model Updates Online", isOn: $config.modelUpdateCheckEnabled)
            Text("Periodically asks Hugging Face if a newer Parakeet model has been published. Updates are never downloaded automatically — you confirm before any change. Leave off for fully offline use.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if config.modelUpdateCheckEnabled {
                Button("Check Now") {
                    Task { await runUpdateCheck() }
                }
                .disabled(updateCheckInFlight)
                if let status = lastUpdateStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summarySections: some View {
        Section("Meeting Summary") {
            Toggle("Summarize After Transcription", isOn: $summaryEnabled)
            Text("Sends the finished transcript to a language model you choose — point it at a local server to keep everything on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if summaryEnabled {
            Section("Provider") {
                Picker("Provider", selection: $summaryProvider) {
                    Text("OpenAI Compatible").tag(SummaryProviderType.openai)
                    Text("LM Studio").tag(SummaryProviderType.lmstudio)
                }
                TextField("Endpoint URL", text: $summaryEndpoint, prompt: Text(
                    summaryProvider == .lmstudio
                        ? "http://127.0.0.1:1234"
                        : "https://api.openai.com/v1"
                ))
                SecureField("API Key", text: $summaryApiKey)
                Text("Leave the key empty for local providers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Model", text: $summaryModel)
            }

            if summaryProvider == .lmstudio {
                Section("Context") {
                    TextField("Context Window (Tokens)", text: $summaryContextLength, prompt: Text("Model default"))
                    TextField("Reserved Overhead (%)", text: $summaryContextOverheadPercent, prompt: Text("Default"))
                    TextField("Max Summary (Tokens)", text: $summaryMaxOutputTokens, prompt: Text("Model default"))
                    Text("How much of the model's context window the transcript may fill, and how long the summary may run. Empty fields use sensible defaults.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Permissions

    @ViewBuilder
    private var permissionsSections: some View {
        Section("Required to Record") {
            PermissionSettingsRow(
                name: "Microphone",
                detail: "Record your voice during meetings",
                status: permissionManager.microphone,
                pane: .microphone,
                onGrant: { Task { await permissionManager.requestMicrophone() } }
            )
            PermissionSettingsRow(
                name: "Screen Recording",
                detail: "Capture system audio from meeting apps",
                status: permissionManager.screenRecording,
                pane: .screenRecording,
                onGrant: { Task { await permissionManager.requestScreenRecording() } }
            )
        }
        Section("Optional") {
            PermissionSettingsRow(
                name: "Calendar",
                detail: "Suggest recording name from current meeting",
                status: permissionManager.calendar,
                pane: .calendar,
                onGrant: { Task { await permissionManager.requestCalendar() } }
            )
            PermissionSettingsRow(
                name: "Notifications",
                detail: "Alert you when transcription finishes",
                status: permissionManager.notifications,
                pane: .notifications,
                onGrant: { Task { await permissionManager.requestNotifications() } }
            )
        }
    }

    // MARK: - Save

    private func save() {
        if summaryEnabled && !summaryEndpoint.isEmpty {
            config.summary = SummaryConfig(
                enabled: true,
                provider: summaryProvider,
                endpoint: summaryEndpoint,
                apiKey: summaryApiKey,
                model: summaryModel,
                contextLength: Int(summaryContextLength),
                contextOverheadPercent: Int(summaryContextOverheadPercent),
                maxOutputTokens: Int(summaryMaxOutputTokens)
            )
        } else {
            config.summary = nil
        }
        config.lastMicrophoneDeviceId = settingsMicId
        configManager.update { $0 = config }
        saveStatus = "Saved"
        // Fire-and-forget: an unstructured Task is not tied to this view's
        // lifetime, so closing Settings does not cancel it. The late write is
        // harmless — it clears @State storage nothing is observing any more.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            saveStatus = nil
        }
        triggerDownloadIfNeeded()
    }

    @ViewBuilder
    private var engineModelStatus: some View {
        switch downloadState {
        case .idle:
            if FluidAudioEngine.isModelCached() && FluidAudioDiarizer.isFullyReady() {
                Label("Model ready", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Model will download ~\(config.engine.descriptor.approximateSizeMB) MB when you save")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(maxWidth: 160)
                Text("\(Int(fraction * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .done:
            Label("Model downloaded", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func runUpdateCheck() async {
        updateCheckInFlight = true
        defer { updateCheckInFlight = false }
        let result = await ModelManifestService.shared.checkForUpdate(
            repo: FluidAudioEngine.parakeetRepoSlug
        )
        switch result {
        case .upToDate(let sha):
            lastUpdateStatus = "Up to date (\(String(sha.prefix(7))))"
        case .updateAvailable(let local, let remote, let when):
            let date = when.map { " · \($0)" } ?? ""
            lastUpdateStatus = "Update available: \(String(local.prefix(7))) → \(String(remote.prefix(7)))\(date). Clear the model cache and re-download from Setup to apply."
        case .noBaseline:
            lastUpdateStatus = "No baseline manifest yet — re-download the model to record one."
        case .checkFailed(let reason):
            lastUpdateStatus = "Check failed: \(reason)"
        }
    }

    private func triggerDownloadIfNeeded() {
        guard config.engine == .fluidAudio else { return }
        let allCached = FluidAudioEngine.isModelCached() && FluidAudioDiarizer.isFullyReady()
        guard !allCached else { return }
        downloadState = .downloading(0)
        downloadTask = Task {
            do {
                try await FluidAudioEngine.preDownloadModel { fraction in
                    Task { @MainActor in
                        guard !Task.isCancelled else { return }
                        downloadState = .downloading(fraction * 0.98)
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { downloadState = .downloading(0.98) }
                try await FluidAudioDiarizer.preDownloadModels()
                guard !Task.isCancelled else { return }
                await MainActor.run { downloadState = .done }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    downloadState = .failed("Download failed — check your connection")
                }
            }
        }
    }
}

private struct PermissionSettingsRow: View {
    let name: String
    let detail: String
    let status: PermissionStatus
    let pane: PrivacyPane
    let onGrant: () -> Void

    var body: some View {
        LabeledContent {
            statusBadge
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .authorized:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notDetermined:
            Button("Grant") { onGrant() }
                .controlSize(.small)
        case .denied:
            // A fresh request can't re-prompt once denied — send the user to
            // the only place it can actually be changed.
            Button("Open Settings") { pane.open() }
                .controlSize(.small)
        }
    }
}
