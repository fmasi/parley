import SwiftUI
import TranscriberCore

struct MicSwitchDialog: View {
    @State private var selectedDeviceId: String?
    @State private var errorMessage: String?
    @State private var isSwitching = false

    let currentDeviceId: String?
    let devices: [AudioInputDevice]
    let buttonLabel: String
    let onSwitch: (String?) async throws -> Void
    let onCancel: () -> Void

    init(
        currentDeviceId: String?,
        devices: [AudioInputDevice],
        buttonLabel: String,
        onSwitch: @escaping (String?) async throws -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._selectedDeviceId = State(initialValue: currentDeviceId)
        self.currentDeviceId = currentDeviceId
        self.devices = devices
        self.buttonLabel = buttonLabel
        self.onSwitch = onSwitch
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change Microphone")
                .font(.headline)

            MicrophonePicker(
                selectedDeviceId: $selectedDeviceId,
                devices: devices
            )

            if let errorMessage {
                // Recoverable failure — orange per the reserved-red policy.
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer()
                if isSwitching {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isSwitching ? "Switching…" : buttonLabel) { performSwitch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSwitching || selectedDeviceId == currentDeviceId)
            }
        }
        .padding(20)
        .frame(width: 380)
        .modifier(GlassBackgroundModifier(cornerRadius: 12))
    }

    private func performSwitch() {
        isSwitching = true
        errorMessage = nil
        Task {
            do {
                try await onSwitch(selectedDeviceId)
            } catch {
                errorMessage = error.localizedDescription
                isSwitching = false
            }
        }
    }
}
