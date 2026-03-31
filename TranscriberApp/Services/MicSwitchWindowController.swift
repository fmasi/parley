import AppKit
import SwiftUI
import TranscriberCore
import os

@MainActor
final class MicSwitchWindowController {
    static let shared = MicSwitchWindowController()
    private var panel: NSPanel?

    func show(
        currentDeviceId: String?,
        onSwitch: @escaping (String?) async throws -> Void
    ) {
        panel?.close()

        let devices = AudioDeviceEnumerator.availableDevices()
        let resolvedId = AudioDeviceEnumerator.resolveDeviceId(
            lastUsed: currentDeviceId, available: devices
        )

        let closePanel = { [weak self] in
            Logger.state.debug("Panel closed: MicSwitch")
            self?.panel?.close()
            self?.panel = nil
        }

        let dialog = MicSwitchDialog(
            currentDeviceId: resolvedId,
            devices: devices,
            onSwitch: { newDeviceId in
                try await onSwitch(newDeviceId)
                await MainActor.run { closePanel() }
            },
            onCancel: closePanel
        )

        let newPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "Change Microphone"
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        let hostingView = NSHostingView(rootView: dialog)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
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
