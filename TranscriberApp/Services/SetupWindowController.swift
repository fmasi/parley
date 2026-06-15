import AppKit
import SwiftUI
import TranscriberCore

@MainActor
final class SetupWindowController {
    static let shared = SetupWindowController()
    private var window: NSWindow?

    func show(
        permissionManager: PermissionManager,
        configManager: ConfigManager,
        onReady: @escaping () -> Void
    ) {
        window?.close()

        let closeWindow = { [weak self] in
            self?.window?.close()
            self?.window = nil
        }

        let view = SetupView(permissionManager: permissionManager, configManager: configManager) {
            closeWindow()
            onReady()
        }

        let hostingView = NSHostingView(rootView: view)
        hostingView.sizingOptions = [.intrinsicContentSize]

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Parley Setup"
        newWindow.contentView = hostingView
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = newWindow
    }
}
