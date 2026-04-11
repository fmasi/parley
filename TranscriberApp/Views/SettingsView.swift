import SwiftUI
import ServiceManagement
import TranscriberCore

private enum DownloadState: Equatable {
    case idle
    case downloading(Double)
    case done
    case failed(String)
}

struct SettingsView: View {
    let configManager: ConfigManager
    @Bindable var permissionManager: PermissionManager
    @State private var config: Config
    @State private var saveStatus: String?
    @State private var downloadState: DownloadState = .idle
    @State private var downloadTask: Task<Void, Never>?
    @State private var archiveUsageBytes: Int = 0
    @State private var summaryEnabled: Bool = false
    @State private var summaryProvider: SummaryProviderType = .openai
    @State private var summaryEndpoint: String = ""
    @State private var summaryApiKey: String = ""
    @State private var summaryModel: String = "gpt-4o-mini"
    @State private var summaryContextLength: String = ""
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
        self._settingsMicId = State(initialValue: configManager.config.lastMicrophoneDeviceId)
    }

    private var isDownloading: Bool {
        if case .downloading = downloadState { return true }
        return false
    }

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionSettingsRow(
                    name: "Microphone",
                    detail: "Record your voice during meetings",
                    status: permissionManager.microphone,
                    onGrant: { Task { await permissionManager.requestMicrophone() } }
                )
                PermissionSettingsRow(
                    name: "Screen Recording",
                    detail: "Capture system audio from meeting apps",
                    status: permissionManager.screenRecording,
                    onGrant: { Task { await permissionManager.requestScreenRecording() } }
                )
                PermissionSettingsRow(
                    name: "Calendar",
                    detail: "Suggest recording name from current meeting",
                    status: permissionManager.calendar,
                    onGrant: { Task { await permissionManager.requestCalendar() } }
                )
                PermissionSettingsRow(
                    name: "Notifications",
                    detail: "Alert you when transcription finishes",
                    status: permissionManager.notifications,
                    onGrant: { Task { await permissionManager.requestNotifications() } }
                )
            }

            Section("Default Microphone") {
                MicrophonePicker(
                    selectedDeviceId: $settingsMicId,
                    devices: settingsMicDevices
                )
                Text("Sessions will start with this microphone unless changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                settingsMicDevices = AudioDeviceEnumerator.availableDevices()
            }

            Section("Transcription Engine") {
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

            Section("Recording") {
                TextField("Recording Directory", text: $config.recordingDirectory)
                Picker("Output Format", selection: $config.outputFormat) {
                    Text("txt").tag("txt")
                    Text("srt").tag("srt")
                    Text("json").tag("json")
                }
            }

            Section("Audio Archive") {
                Picker("Encoding Bitrate", selection: $config.archiveBitrateKbps) {
                    Text("48 kbps").tag(48)
                    Text("64 kbps").tag(64)
                    Text("96 kbps").tag(96)
                    Text("128 kbps").tag(128)
                }

                Stepper(
                    "Keep last \(config.audioArchiveLimitHours) hours",
                    value: $config.audioArchiveLimitHours,
                    in: 1...999
                )

                let estimatedMiB = config.audioArchiveLimitHours * config.archiveBitrateKbps * 1000 / 8 * 3600 / 1_048_576
                Text("≈ \(estimatedMiB) MiB at \(config.archiveBitrateKbps) kbps")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let usageMiB = archiveUsageBytes / 1_048_576
                let usageHours = config.archiveBitrateKbps > 0
                    ? archiveUsageBytes * 8 / (config.archiveBitrateKbps * 1000) / 3600
                    : 0
                Text("\(usageMiB) MiB used (≈ \(usageHours) hours)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .task {
                        archiveUsageBytes = StorageManager.currentUsageBytes(
                            in: URL(fileURLWithPath: config.recordingDirectory)
                        )
                    }
            }

            Section("Silence Detection") {
                Toggle("Enabled", isOn: $config.silenceDetectionEnabled)
                if config.silenceDetectionEnabled {
                    TextField(
                        "Timeout (minutes)",
                        value: $config.silenceTimeoutMinutes,
                        format: .number
                    )
                }
            }

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

            Section("Meeting Summary") {
                Toggle("Auto-summarize after transcription", isOn: $summaryEnabled)
                if summaryEnabled {
                    Picker("Provider", selection: $summaryProvider) {
                        Text("OpenAI Compatible").tag(SummaryProviderType.openai)
                        Text("LM Studio").tag(SummaryProviderType.lmstudio)
                    }
                    TextField("Endpoint URL", text: $summaryEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .help(summaryProvider == .lmstudio
                            ? "LM Studio server (e.g. http://127.0.0.1:1234)"
                            : "OpenAI-compatible endpoint (e.g. https://api.openai.com/v1)")
                    SecureField("API Key", text: $summaryApiKey)
                        .textFieldStyle(.roundedBorder)
                        .help("Leave empty for local providers")
                    TextField("Model", text: $summaryModel)
                        .textFieldStyle(.roundedBorder)
                    if summaryProvider == .lmstudio {
                        TextField("Context Length", text: $summaryContextLength)
                            .textFieldStyle(.roundedBorder)
                            .help("Max tokens for context window (leave empty for model default)")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 600)
        .toolbar {
            ToolbarItem {
                if let status = saveStatus {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem {
                Button("Save") {
                    if summaryEnabled && !summaryEndpoint.isEmpty {
                        config.summary = SummaryConfig(
                            enabled: true,
                            provider: summaryProvider,
                            endpoint: summaryEndpoint,
                            apiKey: summaryApiKey,
                            model: summaryModel,
                            contextLength: Int(summaryContextLength)
                        )
                    } else {
                        config.summary = nil
                    }
                    config.lastMicrophoneDeviceId = settingsMicId
                    configManager.update { $0 = config }
                    saveStatus = "Saved"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        saveStatus = nil
                    }
                    triggerDownloadIfNeeded()
                }
                .disabled(isDownloading)
            }
        }
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
                Text("Model will download ~\(config.engine.descriptor.approximateSizeMB)MB when you save")
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
                .foregroundStyle(.red)
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
    let onGrant: () -> Void

    var body: some View {
        LabeledContent {
            if status.isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant") { onGrant() }
                    .controlSize(.small)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
