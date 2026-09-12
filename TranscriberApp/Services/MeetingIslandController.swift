import AppKit
import SwiftUI
import TranscriberCore
import os

/// The prompt surface (#118, D1): a top-centre, non-activating floating panel — Parley's own window, so
/// it needs no notification permission, ignores Focus, and shows over full-screen call apps without
/// taking focus from them. Created on the first offer, released on withdraw: no idle window, no timer.
/// Follows the `SessionNameWindowController` panel pattern.
@MainActor
final class MeetingIslandController {
    private var panel: NSPanel?
    private var model: MeetingIslandModel?
    /// A `hide()` whose fade-out has not finished. The panel is still on screen and still ours until it
    /// does; a `show()` in that window abandons the fade and starts clean.
    private var isFadingOut = false

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(_ offer: MeetingIslandOffer, expanded: Bool) {
        if isFadingOut { teardown() }
        let shouldAnnounce: Bool
        if let model {
            // Only a different question is worth interrupting VoiceOver again: swapping a subtitle (the
            // calendar title arriving) or re-expanding must not re-announce.
            shouldAnnounce = model.offer.title != offer.title
            model.offer = offer
            model.isExpanded = expanded
            // Every show() restarts the 20 s countdown — including one that leaves `isExpanded`
            // unchanged, which is exactly the stop-offer-replacing-a-start-offer case.
            model.generation += 1
        } else {
            let model = MeetingIslandModel(offer: offer, isExpanded: expanded)
            self.model = model
            panel = makePanel(model: model)
            shouldAnnounce = true
        }
        reposition()
        // A non-activating panel is silent to VoiceOver unless we say something: it never becomes key,
        // so focus never moves into it and nothing is announced on its own.
        if shouldAnnounce {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: "\(offer.title) \(offer.subtitle)",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        Logger.state.debug("Island shown (expanded: \(expanded, privacy: .public))")
    }

    func update(subtitle: String) {
        model?.offer.subtitle = subtitle
    }

    func hide() {
        guard let panel, !isFadingOut else { return }
        isFadingOut = true
        guard !reduceMotion else {
            teardown()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Superseded by a later show()? That one already tore this panel down and built a new
                // one; this completion must not touch the new panel.
                guard let self, self.isFadingOut, self.panel === panel else { return }
                self.teardown()
            }
        })
    }

    /// Drops the window and the model. `close()` (not `orderOut`) so the hosting view is released and
    /// the view's collapse task is cancelled with it. Logged here, not at the start of the fade: until
    /// this runs, the island is still on screen and a racing `show()` can still keep it.
    private func teardown() {
        isFadingOut = false
        panel?.close()
        // Belt and braces, after the window is gone so it can never be seen: collapsing cancels the
        // view's `.task(id:)`, so even a hosting view that outlives its window holds no armed sleep.
        model?.isExpanded = false
        panel = nil
        model = nil
        Logger.state.debug("Island hidden")
    }

    private func makePanel(model: MeetingIslandModel) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: MeetingIslandPlacement.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // Never made key, and borderless panels can't become key anyway without a subclass overriding
        // `canBecomeKey` — deliberately not done: the call app must keep focus while the island is up.
        panel.becomesKeyOnlyIfNeeded = true
        // TODO(device): keep the island out of the user's screen share. Whether macOS 15+ still honours
        // sharingType for ScreenCaptureKit-based sharing is UNVERIFIED — on the device checklist.
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false            // the SwiftUI capsule draws its own shadow
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none    // no AppKit window animation; the fade below is ours
        let hosting = NSHostingView(rootView: MeetingIslandView(model: model))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()       // show without activating Parley
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 1
            }
        }
        return panel
    }

    /// Top-centre of the screen with the menu bar focus, just below the menu bar. The arithmetic
    /// (including the notched/non-notched reasoning) lives in `MeetingIslandPlacement`.
    private func reposition() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrame(MeetingIslandPlacement.panelFrame(visibleFrame: screen.visibleFrame), display: true)
    }
}
