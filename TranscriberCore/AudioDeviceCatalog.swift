import Foundation
import Observation
import os

/// The audio-input device list, scanned OFF the calling thread and cached (#192, gotcha #68).
///
/// `AudioDeviceEnumerator.availableDevices()` runs an `AVCaptureDevice.DiscoverySession`, which reads the
/// CoreAudio HAL — the same HAL whose locks a wedged device holds. It used to run in the menu's `body`
/// (redrawn every tick of the live recording timer) and in the dialogs' window controllers, all on the
/// main thread. Views now read `devices`; code that needs a fresh list awaits `refreshed(timeout:)`,
/// which never waits longer than it is told.
///
/// A scan that NEVER returns (a HAL lock held for good) leaves the list at its last known state until
/// the HAL lets go by itself — e.g. the device is physically removed — or the app is relaunched. That
/// is deliberate: a retry would park another thread in the same HAL wait, the pile-up this type exists
/// to prevent. Callers stay bounded, and the stuck scan is logged after `stuckAfter`.
@Observable
public final class AudioDeviceCatalog: @unchecked Sendable {
    /// Starts its first scan as soon as it is first touched.
    public static let shared: AudioDeviceCatalog = {
        let catalog = AudioDeviceCatalog()
        catalog.refresh()
        return catalog
    }()

    /// The last scanned list, for views. Main-actor: only ever written there — the compiler holds us to it.
    @MainActor public private(set) var devices: [AudioInputDevice] = [AudioInputDevice(id: AudioInputDevice.systemDefaultID, name: "System Default")]

    private let scan: @Sendable () -> [AudioInputDevice]
    private let queue = DispatchQueue(label: "audio-device-catalog")
    /// Guards the state below. A leaf lock: never held across a scan.
    private let lock = NSLock()
    @ObservationIgnored private var latest: [AudioInputDevice]
    @ObservationIgnored private var scanning = false
    /// Callers awaiting the current scan, by token, so one that gives up can take itself off.
    @ObservationIgnored private var waiters: [UInt64: ([AudioInputDevice]) -> Void] = [:]
    @ObservationIgnored private var nextWaiterToken: UInt64 = 0
    @ObservationIgnored private var scanSerial: UInt64 = 0
    /// A scan still running after this long is logged: the list then stays at its last known state.
    private let stuckAfter: TimeInterval

    private static let systemDefaultOnly = [AudioInputDevice(id: AudioInputDevice.systemDefaultID, name: "System Default")]

    public convenience init() {
        self.init(scan: { AudioDeviceEnumerator.availableDevices() })
    }

    /// Test seam: substitute the device scan.
    init(
        scan: @escaping @Sendable () -> [AudioInputDevice],
        stuckAfter: TimeInterval = 5
    ) {
        self.stuckAfter = stuckAfter
        self.latest = Self.systemDefaultOnly
        self.scan = scan
    }

    /// Callers still waiting on the current scan. Test hook for the no-pile-up guarantee.
    var waiterCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }

    /// The last known list, readable from any thread.
    public var latestDevices: [AudioInputDevice] {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// Rescan in the background; returns at once. While a scan is still running — possibly stuck on a
    /// wedged device — further calls join it rather than park another thread in the same HAL wait.
    public func refresh() {
        startScanIfIdle()
    }

    /// A fresh scan — or, if it has not finished within `timeout`, the last known list with
    /// `isFresh == false`, so callers don't treat a device missing from it as unplugged.
    public func refreshed(timeout: TimeInterval) async -> (devices: [AudioInputDevice], isFresh: Bool) {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let token = addWaiter { once.resume(($0, true)) }
            startScanIfIdle()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                // Past its deadline: take the waiter off, so a scan stuck for good doesn't collect one
                // per dialog opened while it hangs. A scan finishing between the removal and the resume
                // below makes this report a fresh list as stale — the safe direction (the dialog keeps
                // the user's mic). Don't fold both into one lock hold: resuming under the lock is worse.
                lock.lock()
                waiters[token] = nil
                lock.unlock()
                once.resume((latestDevices, false))
            }
        }
    }

    /// Register a caller for the next scan result.
    private func addWaiter(_ waiter: @escaping ([AudioInputDevice]) -> Void) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        nextWaiterToken &+= 1
        waiters[nextWaiterToken] = waiter
        return nextWaiterToken
    }

    /// Start a scan unless one is already running; a running one will serve every waiter.
    private func startScanIfIdle() {
        lock.lock()
        let begin = !scanning
        scanning = true
        if begin { scanSerial &+= 1 }
        let serial = scanSerial
        lock.unlock()
        guard begin else { return }

        DispatchQueue.global().asyncAfter(deadline: .now() + stuckAfter) { [self] in
            lock.lock()
            let stuck = scanning && scanSerial == serial
            lock.unlock()
            if stuck {
                Logger.audio.error("Audio input scan still running after \(self.stuckAfter, privacy: .public)s — a device is not responding; the mic list stays at its last known state")
            }
        }

        queue.async { [self] in
            let found = scan()
            lock.lock()
            latest = found
            scanning = false
            let ready = Array(waiters.values)
            waiters = [:]
            lock.unlock()
            // Waiters get `found` itself, synchronously; `devices` is only published after (async, on
            // main). A waiter must use its argument — reading `devices` from inside one sees the old list.
            ready.forEach { $0(found) }
            // A compiler-checked hop to the main actor. Ordering is safe: scans are serialized, so
            // there is one publish per finished scan.
            Task { @MainActor [weak self] in self?.devices = found }
        }
    }
}
