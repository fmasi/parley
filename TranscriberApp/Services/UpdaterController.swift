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
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    // @StateObject (not @ObservedObject) -- this view creates its own ViewModel, so its lifetime
    // must be tied to the view's SwiftUI identity, not to this struct's init running again. With
    // @ObservedObject a parent rebuild (e.g. AppState changing while the menu is open) would
    // reallocate a fresh ViewModel and reset canCheckForUpdates to false until the next KVO tick.
    @StateObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self._viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates...", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
