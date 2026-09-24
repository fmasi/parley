import AppKit
import TranscriberCore

/// Forwards the Mac's sleep, wake and power-off to the coordinator (§8.10). Logout, shutdown and
/// restart all arrive as `willPowerOffNotification`. Fast user switching
/// (`sessionDidResignActiveNotification`) is deliberately not observed: the recording continues.
/// A volume mount and a wake also retry the sessions a relaunch could not finish (an unplugged drive,
/// L follow-up 35): event-driven, never a timer.
@MainActor
final class SystemEventObserver {
    private var observers: [NSObjectProtocol] = []

    init(coordinator: RecordingCoordinator) {
        let center = NSWorkspace.shared.notificationCenter
        // `.main`: every handler runs on the main thread, where the coordinator lives.
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.systemWillSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator else { return }
                coordinator.systemDidWake()
                Task { await coordinator.retryPendingSessions() }
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator else { return }
                Task { await coordinator.retryPendingSessions() }
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator else { return }
                Task { await coordinator.systemWillPowerOff() }
            }
        })
    }
}
