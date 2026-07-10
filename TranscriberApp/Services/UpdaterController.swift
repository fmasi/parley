import SwiftUI
import Sparkle

/// Publishes whether the user can currently trigger an update check (drives the menu item's
/// enabled state — disabled while a check is already in flight).
///
/// No unit tests: its only logic is forwarding `SPUUpdater.canCheckForUpdates` through a
/// `@Published` property, and `SPUUpdater` is a concrete Sparkle framework class with no seam to
/// substitute a fake in a test target. Not a precedent for skipping tests elsewhere — this one
/// genuinely has no testable logic path.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        // Sparkle doesn't document that this KVO publisher fires on the main thread -- receive(on:)
        // makes that assumption explicit rather than relying on it, since publishing to @Published
        // off-main would trigger a SwiftUI re-render from a background thread.
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    // @StateObject (not @ObservedObject) -- this view creates its own ViewModel, so its lifetime
    // must be tied to the view's SwiftUI identity, not to this struct's init running again. With
    // @ObservedObject a parent rebuild (e.g. AppState changing while the menu is open) would
    // reallocate a fresh ViewModel and reset canCheckForUpdates to false until the next KVO tick.
    @StateObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    /// Propagated from the MenuBarExtra content. The old `.menu`-style extra
    /// closed itself on any click; a `.window` panel does not, so every row
    /// that opens external UI must dismiss it explicitly — Sparkle's dialog
    /// would otherwise appear with the panel still hanging open behind it.
    @Environment(\.dismiss) private var dismissPanel

    init(updater: SPUUpdater) {
        self.updater = updater
        self._viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        // Styled as a MenuActionRow so it sits seamlessly among the other rows
        // of the window-style menu bar panel (see Views/DesignSystem.swift).
        MenuActionRow(
            icon: "arrow.triangle.2.circlepath",
            title: "Check for Updates…",
            isDisabled: !viewModel.canCheckForUpdates
        ) {
            dismissPanel()
            updater.checkForUpdates()
        }
    }
}
