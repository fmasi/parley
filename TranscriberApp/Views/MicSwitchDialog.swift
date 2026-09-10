import SwiftUI
import os
import TranscriberCore

struct MicSwitchDialog: View {
    @State private var selectedDeviceId: String?
    @State private var errorMessage: String?
    @State private var isSwitching = false
    @State private var levelMonitor = InputLevelMonitor()

    let currentDeviceId: String?
    let buttonLabel: String
    let onSwitch: (String?) async throws -> Void
    let onCancel: () -> Void

    init(
        currentDeviceId: String?,
        buttonLabel: String,
        onSwitch: @escaping (String?) async throws -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._selectedDeviceId = State(initialValue: currentDeviceId)
        self.currentDeviceId = currentDeviceId
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
                levelMonitor: levelMonitor
            )
            .disabled(isSwitching)   // a new pick would reopen a mic while the helper opens one

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
        let target = selectedDeviceId   // what was chosen at the click, not after the release wait
        Task {
            // Let go of the mic before the capture helper opens it, so the two never contend for the
            // device's HAL IO (#192). Bounded: a wedged meter must not hold up the switch.
            if await !levelMonitor.stopAndRelease(timeout: 1) {
                // Known, accepted overlap (#192): the meter's start is still stuck. Logged so a future
                // hang report can be traced to it.
                Logger.state.warning("Level meter did not release the mic within 1 s — proceeding with the switch anyway")
            }
            do {
                // Success: onSwitch closes the panel. isSwitching stays true on purpose — the button
                // stays disabled until the view is torn down, instead of flickering back to "Switch".
                try await onSwitch(target)
            } catch {
                errorMessage = error.localizedDescription
                isSwitching = false
                levelMonitor.start(deviceId: target)   // the dialog stays open: meter back on
            }
        }
    }
}
