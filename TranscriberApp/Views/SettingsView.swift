import SwiftUI
import ServiceManagement
import TranscriberCore

struct SettingsView: View {
    let configManager: ConfigManager
    @Bindable var permissionManager: PermissionManager
    @State private var config: Config
    @State private var saveStatus: String?

    init(configManager: ConfigManager, permissionManager: PermissionManager) {
        self.configManager = configManager
        self.permissionManager = permissionManager
        self._config = State(initialValue: configManager.config)
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

            Section("Recording") {
                TextField("Recording Directory", text: $config.recordingDirectory)
                Picker("Output Format", selection: $config.outputFormat) {
                    Text("txt").tag("txt")
                    Text("srt").tag("srt")
                    Text("json").tag("json")
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

            Section("Speaker Diarization") {
                SecureField("HuggingFace Token", text: $config.hfToken)
                    .textContentType(.password)
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
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 500)
        .toolbar {
            ToolbarItem {
                if let status = saveStatus {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem {
                Button("Save") {
                    configManager.update { $0 = config }
                    saveStatus = "Saved"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        saveStatus = nil
                    }
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
