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
    /// `NSWorkspace.willPowerOff` was seen: a logout, shutdown or restart is under way.
    static var powerOffSeen = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = TranscriberApp.busyCoordinator else { return .terminateNow }
        // The quit Apple event names a logout, restart or shutdown in `kAEQuitReason` — documented as a
        // parameter, commonly read as an attribute: both are looked at.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let reason = (event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
            ?? event?.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)))?.enumCodeValue
        let kind = TerminationPolicy.kind(quitReason: reason, powerOffSeen: Self.powerOffSeen,
                                          userQuitRequested: Self.userQuitRequested)
        switch TerminationPolicy.reply(busy: coordinator.hasWorkInFlight, kind: kind) {
        case .terminateNow:
            return .terminateNow
        case .terminateLater(let bound):
            Logger.state.info("Termination (\(String(describing: kind), privacy: .public)) with work in flight — stopping the helper first, bounded")
            Task { @MainActor in
                await coordinator.prepareForTermination(bound: bound)
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}
