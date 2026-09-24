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

/// The "Grant" action for a recording permission. Asking is only useful while macOS can still show
/// its prompt, so when it can't the user is taken to the Settings pane where the fix actually is,
/// rather than left with a button that does nothing.
@MainActor
func grantPermission(_ permission: CapturePermission, using manager: PermissionManager) async {
    // CGRequestScreenCaptureAccess never prompts again after a first refusal.
    if permission == .screenRecording { permission.pane.open() }
    await manager.request(permission)
    // A System Audio request that ended without an answer (no prompt, still "never asked") can't be
    // fixed by asking again. `.denied` needs no help: the row already offers "Open Settings".
    if permission == .systemAudioRecording, manager.status(of: permission) == .notDetermined {
        permission.pane.open()
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
                        onGrant: { Task { await grantPermission(permission, using: permissionManager) } }
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
                // This window may have been replaced while the refresh was in flight: a cancelled
                // task must not close its successor.
                if Task.isCancelled { return }
                if unresolved.isEmpty {
                    onResolved()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var explanation: String {
        let shown = unresolved.isEmpty ? permissions : unresolved
        let off = CaptureReadiness.offPhrase(for: shown)
        if isRecording {
            return unresolved.contains(.systemAudioRecording) || unresolved.contains(.screenRecording)
                ? "\(off), so the other side of the call is not being captured. Your recording continues; grant it and remote audio resumes in this same recording."
                : "\(off), so part of this meeting is not being captured. Your recording continues; grant it to fix it."
        }
        return "\(off). Parley needs it to record meetings. Grant it now so your next recording captures everything."
    }
}
