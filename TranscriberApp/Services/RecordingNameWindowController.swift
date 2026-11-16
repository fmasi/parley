import AppKit
import SwiftUI
import TranscriberCore
import os

/// Opens `RecordingNameDialog` as a small titled panel (#358). Not a text field on the meeting island: the island is a
/// borderless non-activating panel that never becomes key, so the call app keeps the keyboard, and it collapses itself
/// after 20 s. A field there would either never take typing or, made key, take the keyboard from the call whenever the
/// pill was touched. This panel becomes key only on an explicit Rename… click, as the naming panel does.
@MainActor
final class RecordingNameWindowController {
    static let shared = RecordingNameWindowController()
    private var panel: NSPanel?

    /// `onSave` gets the typed name; the panel closes either way.
    func show(currentName: String, onSave: @escaping @MainActor (String) -> Void) {
        panel?.close()
        let newPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        // Bound to THIS panel: a late callback from a replaced one must not close a newer one.
        let closePanel = { [weak self, weak newPanel] in
            newPanel?.close()
            if let self, self.panel === newPanel { self.panel = nil }
        }
        let dialog = RecordingNameDialog(
            currentName: currentName,
            onSave: { name in
                closePanel()
                onSave(name)
            },
            onCancel: closePanel
        )
        newPanel.title = "Recording Name"
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        let hostingView = NSHostingView(rootView: dialog)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        newPanel.contentView = hostingView
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.becomesKeyOnlyIfNeeded = false
        newPanel.isReleasedWhenClosed = false
        newPanel.center()
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = newPanel
        Logger.state.debug("Panel shown: RecordingName")
    }

    /// The recording ended while the panel was open: its name is now the rename dialog's.
    func close() {
        panel?.close()
        panel = nil
    }
}
