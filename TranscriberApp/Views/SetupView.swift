import SwiftUI
import TranscriberCore

struct SetupView: View {
    @Bindable var permissionManager: PermissionManager
    let configManager: ConfigManager
    let onReady: () -> Void

    @State private var selectedEngine: EngineID
    @State private var downloadState: DownloadState = .idle

    private var canContinue: Bool {
        permissionManager.allRequiredGranted
    }

    init(permissionManager: PermissionManager, configManager: ConfigManager, onReady: @escaping () -> Void) {
        self.permissionManager = permissionManager
        self.configManager = configManager
        self.onReady = onReady
        self._selectedEngine = State(initialValue: configManager.config.engine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Audio Transcribe needs a few permissions to work")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                PermissionRow(
                    icon: "mic.fill",
                    name: "Microphone",
                    detail: "Record your voice during meetings",
                    status: permissionManager.microphone,
                    onGrant: { Task { await permissionManager.requestMicrophone() } }
                )

                PermissionRow(
                    icon: "rectangle.inset.filled.and.person.filled",
                    name: "Screen Recording",
                    detail: "Capture system audio from meeting apps",
                    status: permissionManager.screenRecording,
                    onGrant: { Task {
                        await permissionManager.requestScreenRecording()
                    }}
                )

                Divider()

                Text("Optional")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                PermissionRow(
                    icon: "calendar",
                    name: "Calendar",
                    detail: "Suggest recording name from current meeting",
                    status: permissionManager.calendar,
                    onGrant: { Task { await permissionManager.requestCalendar() } }
                )

                PermissionRow(
                    icon: "bell.fill",
                    name: "Notifications",
                    detail: "Alert you when transcription finishes",
                    status: permissionManager.notifications,
                    onGrant: { Task { await permissionManager.requestNotifications() } }
                )

                Divider()

                Text("Transcription Engine")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .frame(width: 20)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Engine", selection: $selectedEngine) {
                            ForEach(EngineID.availableEngines) { engine in
                                Text(engine.descriptor.displayName).tag(engine)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: selectedEngine) { _, newEngine in
                            configManager.update { $0.engine = newEngine }
                            startDownloadIfNeeded(for: newEngine)
                        }

                        engineModelStatus
                    }
                }
            }

            HStack {
                Spacer()
                Button("Continue") { onReady() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    @ViewBuilder
    private var engineModelStatus: some View {
        switch downloadState {
        case .idle:
            if selectedEngine.descriptor.requiresModelDownload {
                if FluidAudioEngine.isModelCached() {
                    Label("Model ready", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Model will download ~\(selectedEngine.descriptor.approximateSizeMB)MB in the background")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        case .failed:
            Label("Download failed — check your connection", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func startDownloadIfNeeded(for engine: EngineID) {
        guard engine == .fluidAudio, !FluidAudioEngine.isModelCached() else {
            if engine != .fluidAudio { downloadState = .idle }
            return
        }
        downloadState = .downloading(0)
        Task {
            do {
                try await FluidAudioEngine.preDownloadModel { fraction in
                    Task { @MainActor in
                        downloadState = .downloading(fraction)
                    }
                }
                await MainActor.run { downloadState = .done }
            } catch {
                await MainActor.run { downloadState = .failed("") }
            }
        }
    }
}

private enum DownloadState: Equatable {
    case idle
    case downloading(Double)
    case done
    case failed(String)
}

private struct PermissionRow: View {
    let icon: String
    let name: String
    let detail: String
    let status: PermissionStatus
    let onGrant: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            statusBadge
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
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
    }
}
