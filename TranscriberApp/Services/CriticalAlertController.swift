import AppKit
import SwiftUI
import os

@MainActor
final class CriticalAlertController {
    static let shared = CriticalAlertController()
    private var panel: NSPanel?

    func show(title: String, message: String, onDismiss: (() -> Void)? = nil) {
        panel?.close()

        let closePanel = { [weak self] in
            Logger.state.debug("Critical alert dismissed")
            self?.panel?.close()
            self?.panel = nil
            onDismiss?()
        }

        let dialog = CriticalAlertDialog(
            title: title,
            message: message,
            onDismiss: closePanel
        )

        let newPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "Alert"
        newPanel.contentView = NSHostingView(rootView: dialog)
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.becomesKeyOnlyIfNeeded = false
        newPanel.level = .floating
        newPanel.center()
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Play system alert sound
        NSSound.beep()

        self.panel = newPanel
        Logger.state.debug("Critical alert shown: \(title, privacy: .public)")
    }
}
