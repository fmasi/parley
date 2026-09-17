import AppKit
import SwiftUI
import TranscriberCore

@MainActor
final class SetupWindowController {
    static let shared = SetupWindowController()
    private var window: NSWindow?

    /// `onReady` is `@MainActor` in the type, not merely by convention: both
    /// call sites mutate `LaunchGate.permissionsReady`, which is
    /// `@MainActor`-isolated. Making the contract explicit means the compiler
    /// enforces it rather than the caller remembering.
    func show(
        permissionManager: PermissionManager,
        configManager: ConfigManager,
        onReady: @escaping @MainActor () -> Void
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
        // `.sizingOptions` alone is a no-op once the view is `contentView`
        // (AppKit drives the frame from the window's content rect instead).
        // Disabling the autoresizing-mask translation lets Auto Layout size
        // the window to the view's actual intrinsic content size below.
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let newWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Parley Setup"
        newWindow.contentView = hostingView
        newWindow.contentMinSize = NSSize(width: 460, height: 300)
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = newWindow
    }
}
