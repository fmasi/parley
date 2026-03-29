import SwiftUI
import ServiceManagement

struct SettingsView: View {
    let configManager: ConfigManager
    @State private var config: Config
    @State private var saveStatus: String?

    init(configManager: ConfigManager) {
        self.configManager = configManager
        self._config = State(initialValue: configManager.config)
    }

    var body: some View {
        Form {
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
        .frame(width: 450, height: 380)
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
