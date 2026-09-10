import Foundation
import Testing
@testable import TranscriberCore

/// Carries a non-Sendable value across a thread boundary in a test.
private final class Carry<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// A device scan that blocks until released — a DiscoverySession stuck behind a wedged device's HAL
/// lock. `entered` fires once a scan is actually in progress.
private final class GatedScan: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let result: [AudioInputDevice]
    private let lock = NSLock()
    private var _scans = 0
    private var _threads: [Thread] = []
    init(_ result: [AudioInputDevice]) { self.result = result }
    var scans: Int { lock.lock(); defer { lock.unlock() }; return _scans }
    var threads: [Thread] { lock.lock(); defer { lock.unlock() }; return _threads }
    func scan() -> [AudioInputDevice] {
        lock.lock(); _scans += 1; _threads.append(Thread.current); lock.unlock()
        entered.signal()
        release.wait()
        return result
    }
}

@Suite("AudioDeviceCatalog never scans devices on its caller (#192)")
struct AudioDeviceCatalogTests {

    private let systemDefaultOnly = [AudioInputDevice(id: nil, name: "System Default")]
    private let withUSB = [AudioInputDevice(id: nil, name: "System Default"), AudioInputDevice(id: "usb-1", name: "USB Mic")]

    /// Runs `body` on its own thread; true if it returned within `seconds`.
    private func returnsPromptly(within seconds: Double = 2, _ body: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { body(); done.signal() }
        return done.wait(timeout: .now() + seconds) == .success
    }

    /// Polls `condition` for up to `seconds`.
    private func eventually(within seconds: Double = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private func catalog(_ gate: GatedScan, publish q: DispatchQueue = DispatchQueue(label: "test.publish")) -> AudioDeviceCatalog {
        AudioDeviceCatalog(scan: { gate.scan() }, publish: { q.async(execute: $0) })
    }

    @Test("before any scan it offers System Default, without touching a device")
    func startsWithSystemDefault() {
        let gate = GatedScan(withUSB)
        let c = catalog(gate)
        #expect(c.devices == systemDefaultOnly)
        #expect(c.latestDevices == systemDefaultOnly)
        #expect(gate.scans == 0)
    }

    @Test("refresh() returns even when the scan never does")
    func refreshDoesNotBlock() {
        let gate = GatedScan(withUSB)
        let c = Carry(catalog(gate))
        let ok = returnsPromptly { c.value.refresh() }
        gate.release.signal()
        #expect(ok, "refresh() blocked its caller — from the menu's body this froze the app")
    }

    @Test("the scan runs off the calling thread")
    func scanRunsOffCaller() {
        let gate = GatedScan(withUSB)
        gate.release.signal()
        let c = catalog(gate)
        let caller = Thread.current
        c.refresh()
        #expect(eventually { gate.scans == 1 })
        #expect(gate.threads.allSatisfy { $0 !== caller }, "the device scan ran on the caller's thread")
    }

    @Test("a finished scan reaches views and latestDevices")
    func finishedScanIsPublished() {
        let gate = GatedScan(withUSB)
        gate.release.signal()
        let q = DispatchQueue(label: "test.publish")
        let c = catalog(gate, publish: q)
        c.refresh()
        #expect(eventually { q.sync { c.devices } == withUSB })
        #expect(c.latestDevices == withUSB)
    }

    @Test("refreshes while a scan is stuck join it — no second thread parked on the same device")
    func refreshesCoalesceWhileStuck() {
        let gate = GatedScan(withUSB)
        let c = catalog(gate)
        c.refresh()
        guard gate.entered.wait(timeout: .now() + 2) == .success else {
            Issue.record("the scan never began"); return
        }
        for _ in 0..<5 { c.refresh() }

        // Let the stuck scan finish. Refreshes that were queued rather than joined would now start
        // scanning one after another (and block again on the gate) — so the count must stay at 1.
        gate.release.signal()
        #expect(eventually { c.latestDevices == withUSB })
        // An un-coalesced refresh would now start a scan of its own, which counts itself on ENTRY —
        // before blocking on the gate — so it would show up here within moments.
        #expect(!eventually(within: 0.5) { gate.scans > 1 }, "refreshes made during the stuck scan ran their own scans afterwards")

        gate.release.signal()
        c.refresh()
        #expect(eventually { gate.scans == 2 }, "once the stuck scan finished, a new refresh must scan again")
        Thread.sleep(forTimeInterval: 0.2)
        #expect(gate.scans == 2)
    }

    @Test("refreshed(timeout:) hands back the fresh list when the scan finishes in time")
    func refreshedReturnsFreshList() async {
        let gate = GatedScan(withUSB)
        gate.release.signal()
        let c = catalog(gate)
        let scan = await c.refreshed(timeout: 2)
        #expect(scan.devices == withUSB)
        #expect(scan.isFresh)
    }

    @Test("refreshed(timeout:) falls back to the last known list when the scan is stuck")
    func refreshedFallsBackWhenStuck() async {
        let gate = GatedScan(withUSB)
        let c = catalog(gate)
        let began = Date()
        let scan = await c.refreshed(timeout: 0.2)
        let waited = Date().timeIntervalSince(began)
        gate.release.signal()
        #expect(scan.devices == systemDefaultOnly)
        #expect(!scan.isFresh, "a stale list reported as fresh would make the dialog drop the user's mic")
        #expect(waited < 5, "waited \(waited)s — opening the mic switcher would hang behind the scan")
    }

    @Test("callers that gave up on a stuck scan leave nothing behind")
    func timedOutWaitersAreDropped() async {
        let gate = GatedScan(withUSB)
        let c = catalog(gate)
        for _ in 0..<5 { _ = await c.refreshed(timeout: 0.05) }
        #expect(c.waiterCount == 0, "each dialog opened during a stuck scan left a waiter behind for good")
        gate.release.signal()
    }
}
