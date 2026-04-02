import SwiftUI
import TranscriberCore

struct SetupView: View {
    @Bindable var permissionManager: PermissionManager
    let onReady: () -> Void

    private var canContinue: Bool {
        permissionManager.allRequiredGranted
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
