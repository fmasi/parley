import AppKit
import SwiftUI
import TranscriberCore
import os

@MainActor
final class MicSwitchWindowController {
    static let shared = MicSwitchWindowController()
    private var panel: NSPanel?
    /// The latest show(); an earlier one still awaiting its device scan must not open a second panel.
    private var pendingRequest: UUID?

    func show(
        currentDeviceId: String?,
        buttonLabel: String,
        onSwitch: @escaping (String?) async throws -> Void
    ) {
        panel?.close()
        panel = nil
        let request = UUID()
        pendingRequest = request
        Task {
            // Scan devices off the main thread, bounded: a wedged audio device must not freeze the app
            // (#192). Past the deadline the dialog opens with the last known list.
            let scan = await AudioDeviceCatalog.shared.refreshed(timeout: 1)
            guard pendingRequest == request else { return }   // superseded by a later show()
            present(scan: scan, currentDeviceId: currentDeviceId, buttonLabel: buttonLabel, onSwitch: onSwitch)
        }
    }

    private func present(
        scan: (devices: [AudioInputDevice], isFresh: Bool),
        currentDeviceId: String?,
        buttonLabel: String,
        onSwitch: @escaping (String?) async throws -> Void
    ) {
        let resolvedId = AudioDeviceEnumerator.resolveDeviceId(
            lastUsed: currentDeviceId, available: scan.devices, listIsFresh: scan.isFresh
        )

        let newPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        // Bound to THIS panel: a late callback from a closed or replaced dialog must not close a newer one.
        let closePanel = { [weak self, weak newPanel] in
            Logger.state.debug("Panel closed: MicSwitch")
            newPanel?.close()
            if let self, self.panel === newPanel { self.panel = nil }
        }
        /// False once this panel was closed (Cancel, Esc, its close button) or replaced. The dialog waits
        /// up to a second for its level meter to let go of the mic before acting (#192); a Cancel in that
        /// wait must win.
        let isLive = { [weak self, weak newPanel] () -> Bool in
            guard let self, let newPanel else { return false }
            return self.panel === newPanel && newPanel.isVisible
        }

        let dialog = MicSwitchDialog(
            currentDeviceId: resolvedId,
            buttonLabel: buttonLabel,
            onSwitch: { newDeviceId in
                // Cancelled while the meter was releasing the mic: don't switch.
                guard await MainActor.run(body: { isLive() }) else { return }
                try await onSwitch(newDeviceId)
                await MainActor.run { closePanel() }
            },
            onCancel: closePanel
        )

        newPanel.title = "Change Microphone"
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        let hostingView = NSHostingView(rootView: dialog)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        newPanel.contentView = hostingView
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.becomesKeyOnlyIfNeeded = false
        newPanel.center()
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = newPanel
        Logger.state.debug("Panel shown: MicSwitch")
    }
}
