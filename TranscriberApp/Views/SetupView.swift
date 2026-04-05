import SwiftUI
import TranscriberCore

struct SetupView: View {
    @Bindable var permissionManager: PermissionManager
    let configManager: ConfigManager
    let onReady: () -> Void

    @State private var selectedEngine: EngineID
    @State private var downloadState: DownloadState = .idle
    @State private var downloadTask: Task<Void, Never>?
    @State private var folderAccessGranted = false

    private var modelReady: Bool {
        !selectedEngine.descriptor.requiresModelDownload
            || (FluidAudioEngine.isModelCached() && FluidAudioDiarizer.isFullyReady())
            || downloadState == .done
    }

    private var canContinue: Bool {
        permissionManager.allRequiredGranted && modelReady && folderAccessGranted
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
                    onGrant: { Task { await permissionManager.requestScreenRecording() } }
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

                Text("Storage")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                FolderAccessRow(
                    directory: configManager.config.recordingDirectory,
                    isGranted: $folderAccessGranted
                )

                Divider()

                Text("Transcription Engine")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                engineRow
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
    private var engineRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .frame(width: 20)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Engine").fontWeight(.medium)
                    Picker("Engine", selection: $selectedEngine) {
                        ForEach(EngineID.availableEngines) { engine in
                            Text(engine.descriptor.displayName).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: selectedEngine) { _, newEngine in
                        configManager.update { $0.engine = newEngine }
                        downloadTask?.cancel()
                        downloadTask = nil
                        downloadState = .idle
                    }
                }

                Spacer()

                engineBadge
            }

            // Full-width progress bar shown while downloading
            if case .downloading(let fraction) = downloadState {
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                    Text("\(Int(fraction * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(.leading, 32)
            }
        }
    }

    @ViewBuilder
    private var engineBadge: some View {
        if selectedEngine.descriptor.requiresModelDownload {
            switch downloadState {
            case .idle:
                if FluidAudioEngine.isModelCached() && FluidAudioDiarizer.isFullyReady() {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Download") { startDownload() }
                        .controlSize(.small)
                }
            case .downloading:
                EmptyView()
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Button("Retry") { startDownload() }
                    .controlSize(.small)
                    .foregroundStyle(.red)
            }
        }
    }

    private func startDownload() {
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
                    downloadState = .failed(error.localizedDescription)
                }
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

private struct FolderAccessRow: View {
    let directory: String
    @Binding var isGranted: Bool
    @State private var denied = false

    private var normalizedDirectory: String {
        ((directory as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .frame(width: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recording Folder").fontWeight(.medium)
                Text(normalizedDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if denied {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            } else {
                Button("Grant") { Task { await verifyAccess() } }
                    .controlSize(.small)
            }
        }
        .task { await verifyAccess() }
    }

    private func verifyAccess() async {
        let dir = normalizedDirectory
        let result = await Task.detached {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true
                )
                // Enumerate the directory — same TCC code path as StorageManager.currentUsageBytes,
                // so the system prompt fires here (during setup) rather than later in Settings.
                _ = try FileManager.default.contentsOfDirectory(atPath: dir)
                return true
            } catch {
                return false
            }
        }.value

        isGranted = result
        denied = !result
    }
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
