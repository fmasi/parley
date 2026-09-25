import AppKit
import CoreServices
import TranscriberCore
import os

/// Answers `applicationShouldTerminate` (L10 review 53). Without it, a logout, shutdown or restart — and a
/// quit from Activity Monitor, `osascript` or Sparkle — ended the process at once, and a recording's stop
/// never ran. `TerminationPolicy` decides; this only reads what kind of termination it is and carries it out.
@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    /// Parley's own Quit asked (confirmed, its recording already stopped within its bound): answered at once.
    static var userQuitRequested = false
    /// When `NSWorkspace.willPowerOff` was last seen: a logout, shutdown or restart under way — or one the user
    /// then cancelled, which is why it counts only for `TerminationPolicy.powerOffWindow` (L review 107).
    static var powerOffSeenAt: Date?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = TranscriberApp.busyCoordinator else { return .terminateNow }
        // The quit Apple event names a logout, restart or shutdown in `kAEQuitReason` — documented as a
        // parameter, commonly read as an attribute: both are looked at.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let reason = (event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
            ?? event?.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)))?.enumCodeValue
        let kind = TerminationPolicy.kind(quitReason: reason, powerOffSeenAt: Self.powerOffSeenAt, now: Date(),
                                          userQuitRequested: Self.userQuitRequested)
        switch TerminationPolicy.reply(busy: coordinator.hasWorkInFlight, kind: kind) {
        case .terminateNow:
            return .terminateNow
        case .terminateLater(let bound):
            Logger.state.info("Termination (\(String(describing: kind), privacy: .public)) with work in flight — stopping the helper first, bounded")
            // Synchronously, before any Task (L review 85): the process may end in this very turn.
            coordinator.markForTermination()
            Task { @MainActor in
                await coordinator.prepareForTermination(bound: bound)
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    /// Every `NSApp.terminate` ends here — the idle `.terminateNow` too, and the quit or termination whose preparation
    /// already flushed (L review 141): the live logs' queued lines reach the disk, bounded — a hung folder never holds
    /// the exit longer than this.
    func applicationWillTerminate(_ notification: Notification) {
        // The preparation's own flush already ran out of its bound (L review 195): a folder is not answering — a second wait
        // here would only hold the exit past the termination's bound. Its queued lines go with the process.
        if TranscriberApp.busyCoordinator?.exitFlushTimedOut == true {
            Logger.state.error("The exit's flush already ran out of its bound — the last flush is skipped")
            return
        }
        if !LiveDiagnosticsLog.flushAll(within: Self.exitFlushBound) {
            Logger.state.error("A recording folder did not answer the exit's flush — its last queued diagnostic lines are lost")
        }
    }

    /// The bound on the exit's synchronous flush (the main thread waits on it).
    static let exitFlushBound: Double = 1
}
