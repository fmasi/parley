import CoreGraphics
import Testing
@testable import TranscriberCore

/// Where the meeting-sensing island panel goes (#118). The panel itself is AppKit and lives in the app
/// target; the arithmetic that decides its frame is pure, so it lives here where a test can reach it.
/// Screen coordinates: origin bottom-left, y up, and `visibleFrame` already excludes the menu bar (and,
/// on a notched display, the notch row) — which is why one rule fits notched and non-notched displays.
///
/// These pin the PANEL only. Where the pill lands inside it is SwiftUI layout in `MeetingIslandView`,
/// and is verified on device — asserting it here would only pin a copy of the rule.
@Suite("MeetingIslandPlacement")
struct MeetingIslandPlacementTests {
    /// A 16:10 display with a menu bar, in the coordinate space a primary screen gets.
    private let primary = CGRect(x: 0, y: 0, width: 1512, height: 957)

    @Test("the locked pill sizes")
    func sizes() {
        // Fixed by the plan so the panel never needs a SwiftUI-driven resize.
        #expect(MeetingIslandPlacement.expandedSize == CGSize(width: 440, height: 56))
        #expect(MeetingIslandPlacement.compactSize == CGSize(width: 150, height: 28))
    }

    @Test("the panel is wider and taller than the pill, to give the shadow room")
    func panelSizeHasRoomForTheShadow() {
        let panel = MeetingIslandPlacement.panelSize
        #expect(panel.width > MeetingIslandPlacement.expandedSize.width)
        #expect(panel.height > MeetingIslandPlacement.expandedSize.height)
    }

    @Test("horizontally centred on the screen")
    func centred() {
        let frame = MeetingIslandPlacement.panelFrame(visibleFrame: primary)
        #expect(frame.midX == primary.midX)
        #expect(frame.size == MeetingIslandPlacement.panelSize)
    }

    @Test("the panel never overlaps the menu bar")
    func flushWithTheTopOfTheVisibleFrame() {
        // The transparent margin around the pill would otherwise sit ON the menu bar. Transparent
        // pixels pass clicks through, but there is no reason to gamble the menu bar on that.
        let frame = MeetingIslandPlacement.panelFrame(visibleFrame: primary)
        #expect(frame.maxY == primary.maxY)
        #expect(primary.contains(frame))
    }

    @Test("a secondary display's coordinate space is honoured")
    func secondaryDisplay() {
        // A display left of and above the primary: negative x, y beyond the primary's height.
        let secondary = CGRect(x: -1920, y: 300, width: 1920, height: 1055)
        let frame = MeetingIslandPlacement.panelFrame(visibleFrame: secondary)
        #expect(frame.midX == secondary.midX)
        #expect(frame.maxY == secondary.maxY)
        #expect(secondary.contains(frame))
    }

    @Test("a display exactly as wide as the panel still fits, flush to both edges")
    func exactFit() {
        let exact = CGRect(x: 40, y: 0, width: MeetingIslandPlacement.panelSize.width, height: 600)
        let frame = MeetingIslandPlacement.panelFrame(visibleFrame: exact)
        #expect(frame.minX == exact.minX)
        #expect(frame.maxX == exact.maxX)
        #expect(exact.contains(frame))
    }

    @Test("a screen narrower than the panel keeps the left edge on screen and overhangs right")
    func narrowerThanThePanel() {
        // Degenerate: no Mac display is 320 pt wide. The pill's size is fixed, so something has to give
        // — this pins WHICH edge gives, rather than leaving it to the arithmetic.
        let narrow = CGRect(x: 0, y: 0, width: 320, height: 480)
        let frame = MeetingIslandPlacement.panelFrame(visibleFrame: narrow)
        #expect(frame.minX == narrow.minX)
        #expect(frame.maxY == narrow.maxY)
        #expect(frame.size == MeetingIslandPlacement.panelSize)   // never resized, only moved
        #expect(frame.maxX > narrow.maxX)                          // deliberate, and only reachable here
    }
}

/// The collapse loop: one sleep at a time, collapse once, and a pointer on the pill defers rather than
/// cancels. Driven with an injected sleep so the 20 s wait doesn't have to be real.
@Suite("MeetingIslandCollapse")
@MainActor
struct MeetingIslandCollapseTests {
    @MainActor
    final class Spy {
        var sleeps = 0
        var collapses = 0
    }

    @Test("an untouched island collapses after exactly one delay, then the loop stops")
    func collapsesOnce() async {
        let spy = Spy()
        await MeetingIslandCollapse.run(
            sleep: { spy.sleeps += 1; await Task.yield() },
            isHovering: { false },
            collapse: { spy.collapses += 1 }
        )
        #expect(spy.sleeps == 1)
        #expect(spy.collapses == 1)
    }

    @Test("a pointer on the pill defers the collapse; it fires on the first expiry after it leaves")
    func rearmsWhileHovering() async {
        let spy = Spy()
        await MeetingIslandCollapse.run(
            sleep: { spy.sleeps += 1; await Task.yield() },
            isHovering: { spy.sleeps < 3 },   // pointer leaves before the third expiry
            collapse: { spy.collapses += 1 }
        )
        #expect(spy.sleeps == 3)
        #expect(spy.collapses == 1)
    }

    @Test("a cancelled loop collapses nothing — the panel is going away on its own")
    func cancellationCollapsesNothing() async {
        let spy = Spy()
        let task = Task { @MainActor in
            await MeetingIslandCollapse.run(
                sleep: { try? await Task.sleep(for: .seconds(30)) },
                isHovering: { false },
                collapse: { spy.collapses += 1 }
            )
        }
        task.cancel()
        await task.value
        #expect(spy.collapses == 0)
    }
}
