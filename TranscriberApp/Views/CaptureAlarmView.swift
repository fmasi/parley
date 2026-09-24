import SwiftUI
import TranscriberCore

/// Display metadata for a capture alarm, shared by the menu's sticky rows and the alarm window.
extension AlarmKind {
    var symbolName: String {
        switch self {
        case .crashProtectionOff: return "shield.slash"
        case .diskLow, .diskWriteFailure, .rotationFailed, .sessionWriteFailed, .recordingFolderUnavailable:
            return "externaldrive.badge.exclamationmark"
        default:
            switch track {
            case .system: return "speaker.slash.fill"
            case .mic: return "mic.slash.fill"
            case nil: return "exclamationmark.triangle"
            }
        }
    }

    var headline: String {
        switch self {
        case .crashProtectionOff: return "Crash protection is off"
        case .micNotDelivering, .micDigitalSilence: return "Your microphone isn’t being recorded"
        case .remoteNotDelivering, .remoteRecoveryFailed, .remotePermissionDenied, .remoteCantConfirm:
            return "The other side may not be recorded"
        case .diskLow, .diskWriteFailure, .rotationFailed, .sessionWriteFailed: return "Recording to disk is in trouble"
        case .helperUnresponsive: return "The capture helper stopped answering"
        case .recordingResumedWithGap: return "Recording resumed after a crash"
        case .recordingStopped: return "Recording STOPPED"
        case .recordingFolderUnavailable: return "Recording folder unavailable"
        case .unknownHelperAlarm: return "Parley needs an update to show a capture problem"
        }
    }
}

/// The alarm window (§6.3): every active alarm with the one action it has. Nothing here dismisses a
/// live condition — only past events can be acknowledged; "Later" just hides the window for a while.
struct CaptureAlarmView: View {
    let alarms: [ActiveAlarm]
    let onLater: () -> Void
    let onAcknowledge: (AlarmKind) -> Void

    static let preferredWidth: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Parley isn’t recording everything")
                        .font(.headline)
                    Text("Each problem stays listed until it is fixed or, for a past event, until you acknowledge it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(alarms, id: \.kind) { alarm in
                    row(alarm)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack {
                Spacer()
                Button("Later") { onLater() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: Self.preferredWidth)
    }

    private func row(_ alarm: ActiveAlarm) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: alarm.kind.symbolName)
                .foregroundStyle(.red)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(alarm.kind.headline)
                    .font(.callout.weight(.semibold))
                Text(alarm.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if alarm.kind == .remotePermissionDenied {
                Button("Open System Settings") { PrivacyPane.systemAudioRecording.open() }
                    .controlSize(.small)
            }
            if alarm.kind.isAcknowledgeable {
                Button("Acknowledge") { onAcknowledge(alarm.kind) }
                    .controlSize(.small)
            }
        }
    }
}
