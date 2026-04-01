import SwiftUI
import TranscriberCore

struct SetupView: View {
    @Bindable var permissionManager: PermissionManager
    let modelManager: ModelManager
    let onReady: () -> Void

    private var canContinue: Bool {
        permissionManager.allRequiredGranted && modelManager.isModelDownloaded("large-v3-turbo")
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

                Text("Transcription Model")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ModelDownloadRow(modelManager: modelManager)
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
}

private struct ModelDownloadRow: View {
    let modelManager: ModelManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .frame(width: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Whisper Model").fontWeight(.medium)
                if modelManager.isDownloading {
                    ProgressView(value: modelManager.downloadProgress)
                        .frame(width: 150)
                } else if let error = modelManager.downloadError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text("Required for transcription (~1.6 GB)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if modelManager.isModelDownloaded("large-v3-turbo") {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if modelManager.isDownloading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(modelManager.downloadError != nil ? "Retry" : "Download") {
                    Task {
                        try? await modelManager.downloadModel("large-v3-turbo")
                    }
                }
                .controlSize(.small)
            }
        }
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
