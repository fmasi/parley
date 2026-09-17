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

        // Left at the AppKit default (true): the hosting view fills the
        // window's content area and resizes with it. `.sizingOptions` alone
        // (the old approach) was a no-op once the view became `contentView`,
        // and disabling autoresizing-mask translation would pin the view to
        // its initial size — leaving dead space below the footer if the user
        // drags the (resizable) window taller.
        let hostingView = NSHostingView(rootView: view)

        let newWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Parley Setup"
        newWindow.contentView = hostingView
        // Width is fixed (SetupView has no flexible-width content); only
        // height is meant to be resizable, down to a scrollable floor.
        newWindow.contentMinSize = NSSize(width: SetupView.preferredSize.width, height: 300)
        newWindow.contentMaxSize = NSSize(width: SetupView.preferredSize.width, height: .greatestFiniteMagnitude)
        newWindow.isReleasedWhenClosed = false
        // `center()` centers on the window's CURRENT frame, which would
        // still be `.zero` at this point without an explicit size — set the
        // shared preferred size (SetupView.preferredSize, so it can't drift
        // out of sync with the view's own `.frame`) before centering.
        newWindow.setContentSize(SetupView.preferredSize)
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = newWindow
    }
}
