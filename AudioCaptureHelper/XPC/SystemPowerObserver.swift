import Foundation
import IOKit
import IOKit.pwr_mgt
import os

/// The helper's own sleep/wake, from IOKit (H2 round 2 item 18), so the liveness pause does not depend
/// on the app's "sleep"/"wake" messages alone: those can be lost or reordered, and the app may not get
/// its message out before the machine sleeps.
///
/// - `kIOMessageSystemWillSleep` → `.willSleep` (an implicit sleep, idempotent with the app's). It and
///   `kIOMessageCanSystemSleep` are acknowledged at once: an unacknowledged one delays sleep 30 s.
/// - `kIOMessageSystemHasPoweredOn` → `.poweredOn(fullWake:)`. It is also sent for a DarkWake / Power Nap,
///   so it carries whether the graphics capability is up (`isFullWake()`): only a full wake may end the
///   pause, since a DarkWake's audio devices may be off.
/// Events arrive on the queue given to `init`.
final class SystemPowerObserver {
    enum Event {
        case willSleep
        /// true = full (user) wake, false = DarkWake, nil = could not tell.
        case poweredOn(fullWake: Bool?)
    }

    // `iokit_common_msg(x)` is a function-like C macro, not imported into Swift:
    // sys_iokit (err_system(0x38) = 0xE0000000) | sub_iokit_common (0) | x.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let onEvent: (Event) -> Void
    /// Registration succeeded. When it didn't, the sleep pause falls back to a plain uptime expiry.
    private(set) var isRegistered = false

    init(queue: DispatchQueue, onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notificationPort, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            Unmanaged<SystemPowerObserver>.fromOpaque(refcon).takeUnretainedValue().handle(messageType, messageArgument)
        }, &notifier)
        guard rootPort != 0, let notificationPort else {
            Logger.audio.error("IORegisterForSystemPower failed — the sleep pause relies on the app's wake and a 30 s expiry")
            return
        }
        IONotificationPortSetDispatchQueue(notificationPort, queue)
        isRegistered = true
    }

    deinit {
        guard isRegistered else { return }
        IODeregisterForSystemPower(&notifier)
        IONotificationPortDestroy(notificationPort)
        IOServiceClose(rootPort)
    }

    private func handle(_ messageType: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemWillSleep:
            onEvent(.willSleep)
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemHasPoweredOn:
            onEvent(.poweredOn(fullWake: Self.isFullWake()))
        default:
            break
        }
    }

    /// Whether the machine is in a full (user) wake: the graphics capability in IOPMrootDomain's
    /// "System Capabilities" (a DarkWake has CPU/network only). An undocumented registry property,
    /// read-only (no private symbol); nil when unreadable. X1 device check: `pmset -g log` DarkWake
    /// entries against the helper's log.
    static func isFullWake() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "System Capabilities" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return value.uint32Value & UInt32(kIOPMSystemCapabilityGraphics) != 0
    }
}
