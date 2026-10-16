import CoreGraphics
import Foundation

/// Where the meeting-sensing island sits, and how big it is (#118). The panel is AppKit and lives in
/// the app target; this is the arithmetic behind it, kept pure so it can be tested without a screen.
///
/// Screen coordinates: origin bottom-left, y up. `NSScreen.visibleFrame` already excludes the menu bar
/// (and, on a notched display, the notch row), so ONE rule places the island correctly on notched and
/// non-notched displays alike — hugging the notch was rejected in planning because a pill at menu-bar
/// height collides with menu-bar items.
///
/// The panel is deliberately bigger than the pill and never resizes: the pill's drop shadow needs room,
/// and a fixed panel lets the expanded → compact change be a SwiftUI animation inside a still window
/// rather than a window resize. The surrounding margin is fully transparent.
///
/// Scope: this covers the panel — the window the controller positions. Where the pill lands *inside*
/// that panel is SwiftUI's layout (`.padding(.top, topGap)` + top alignment in `MeetingIslandView`);
/// it shares `topGap` with this file but is otherwise a device-test concern, deliberately not mirrored
/// here as a second copy of the rule.
public enum MeetingIslandPlacement {
    /// Locked by the plan: the pill never asks SwiftUI for a size.
    public static let expandedSize = CGSize(width: 440, height: 56)
    public static let compactSize = CGSize(width: 150, height: 28)

    /// Gap between the bottom of the menu bar and the top of the pill. Also the panel's top margin, so
    /// the panel itself never overlaps the menu bar.
    public static let topGap: CGFloat = 8
    /// Transparent margin left/right of, and below, the pill — room for the shadow, which a window
    /// cannot draw outside its own frame.
    public static let sideInset: CGFloat = 24
    public static let bottomInset: CGFloat = 24

    public static var panelSize: CGSize {
        CGSize(width: expandedSize.width + 2 * sideInset,
               height: expandedSize.height + topGap + bottomInset)
    }

    /// The panel frame for a screen's `visibleFrame`: horizontally centred, hung from the top of the
    /// visible area, clamped so it never hangs off an edge — moved, never resized, because the pill's
    /// size is fixed.
    ///
    /// The clamp cannot save a display narrower than `panelSize.width` (488 pt): there, keeping the
    /// left edge on screen is the best available outcome and the right edge overhangs. No Mac display
    /// is that narrow in points, so this is a guard against a degenerate `visibleFrame`, not a layout
    /// the user can reach.
    public static func panelFrame(visibleFrame: CGRect) -> CGRect {
        let size = panelSize
        let centredX = visibleFrame.midX - size.width / 2
        let rightmost = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let x = max(visibleFrame.minX, min(centredX, rightmost))
        return CGRect(x: x,
                      y: visibleFrame.maxY - size.height,
                      width: size.width,
                      height: size.height)
    }
}

/// The island's expanded → compact collapse loop, kept out of the view so it can be tested with an
/// injected sleep.
///
/// It holds ONE sleep at a time and nothing at all while no offer is on screen (no island, no window,
/// no task). It does re-arm — but only while the pointer rests on the pill, so the island never
/// shrinks out from under the cursor; once the pointer leaves, the next expiry collapses it and the
/// loop returns for good.
public enum MeetingIslandCollapse {
    public static let delaySeconds: Double = 20

    /// - Parameters:
    ///   - sleep: waits one collapse delay. Must return early when the task is cancelled (a cancelled
    ///     `Task.sleep` does), or the loop cannot exit promptly.
    ///   - isHovering: whether the pointer is on the pill at the moment the delay expires.
    ///   - collapse: called at most once, and only when the island really should collapse.
    @MainActor
    public static func run(
        sleep: @MainActor () async -> Void,
        isHovering: @MainActor () -> Bool,
        collapse: @MainActor () -> Void
    ) async {
        while !Task.isCancelled {
            await sleep()
            if Task.isCancelled { return }
            guard isHovering() else {
                collapse()
                return
            }
        }
    }
}
