import AppKit
import SwiftUI

@MainActor
final class SessionNameWindowController {
    static let shared = SessionNameWindowController()
    private var panel: NSPanel?

    func show(suggestedName: String?, onStart: @escaping (String) -> Void) {
        panel?.close()

        let closePanel = { [weak self] in
            self?.panel?.close()
            self?.panel = nil
        }

        let dialog = SessionNameDialog(
            suggestedName: suggestedName ?? "",
            onStart: { name in
                closePanel()
                onStart(name)
            },
            onCancel: closePanel
        )

        let newPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "New Recording"
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        let hostingView = NSHostingView(rootView: dialog)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        newPanel.contentView = hostingView
        newPanel.isFloatingPanel = true
        newPanel.becomesKeyOnlyIfNeeded = false
        newPanel.center()
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = newPanel
    }
}
