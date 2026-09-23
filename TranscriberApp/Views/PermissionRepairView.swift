import SwiftUI
import TranscriberCore

/// Display metadata for a recording permission, shared by Setup, Settings, and the repair window.
extension CapturePermission {
    var tile: IconTile {
        switch self {
        case .microphone: return IconTile(systemImage: "mic.fill", color: .red)
        case .screenRecording: return IconTile(systemImage: "rectangle.inset.filled.and.person.filled", color: .blue)
        case .systemAudioRecording: return IconTile(systemImage: "speaker.wave.2.fill", color: .blue)
        }
    }

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .screenRecording: return "Screen Recording"
        case .systemAudioRecording: return "System Audio Recording"
        }
    }

    var detail: String {
        switch self {
        case .microphone: return "Record your voice during meetings"
        case .screenRecording: return "Capture system audio from meeting apps"
        case .systemAudioRecording: return "Capture the other side of calls and meetings"
        }
    }

    var pane: PrivacyPane {
        switch self {
        case .microphone: return .microphone
        case .screenRecording: return .screenRecording
        case .systemAudioRecording: return .systemAudioRecording
        }
    }
}

/// The repair window (#220, #174): names exactly which recording permission is missing and fixes it
/// in one click. Refreshes every 2 s while open, which is the only time anything polls, and reports
/// back as soon as everything it lists is granted.
struct PermissionRepairView: View {
    let permissionManager: PermissionManager
    let appState: AppState
    /// The permissions this window was opened for. Rows stay listed (turning green) once fixed.
    let permissions: [CapturePermission]
    /// Opened because of a recording (starting or running): word it that way even in the moment
    /// before the phase flips to `.recording`.
    let assumeRecording: Bool
    let onResolved: () -> Void
    let onDismiss: () -> Void

    /// Read live, so a window opened before a recording started says the right thing once it has.
    private var isRecording: Bool { assumeRecording || appState.isRecording }

    static let preferredSize = NSSize(width: 460, height: 300)

    private var unresolved: [CapturePermission] {
        permissions.filter { !permissionManager.status(of: $0).isGranted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isRecording ? "Parley isn’t recording everything" : "Parley needs a permission to record")
                        .font(.headline)
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 10) {
                ForEach(permissions, id: \.self) { permission in
                    PermissionRow(
                        tile: permission.tile,
                        name: permission.displayName,
                        detail: permission.detail,
                        status: permissionManager.status(of: permission),
                        pane: permission.pane,
                        onGrant: {
                            // CGRequestScreenCaptureAccess never prompts again after a first refusal:
                            // take the user where the fix actually is.
                            if permission == .screenRecording { permission.pane.open() }
                            Task { await permissionManager.request(permission) }
                        }
                    )
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("This window closes by itself once the permission is granted.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Later") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: Self.preferredSize.width)
        .task {
            // Poll only while this window is open: the user is fixing the permission in System
            // Settings right now, and Parley has no notification for the change.
            while !Task.isCancelled {
                await permissionManager.refreshRequired()
                if unresolved.isEmpty {
                    onResolved()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var explanation: String {
        let names = unresolved.map(\.displayName)
        let list = ListFormatter.localizedString(byJoining: names.isEmpty ? permissions.map(\.displayName) : names)
        if isRecording {
            return unresolved.contains(.systemAudioRecording) || unresolved.contains(.screenRecording)
                ? "\(list) is off, so the other side of the call is not being captured. Your recording continues; grant it and remote audio resumes in this same recording."
                : "\(list) is off, so part of this meeting is not being captured. Your recording continues; grant it to fix it."
        }
        return "\(list) is needed to record meetings. Grant it now so your next recording captures everything."
    }
}
