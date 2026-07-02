import Foundation
import Testing
@testable import TranscriberCore

@Suite("SingleInstanceGuard")
struct SingleInstanceGuardTests {

    /// A unique lock path under the temp dir for each test (no shared state between tests).
    private func tempLockPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parley-instance-\(UUID().uuidString).lock")
            .path
    }

    @Test("First instance acquires the lock")
    func firstAcquires() {
        let path = tempLockPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        guard case .acquired(let fd) = SingleInstanceGuard.acquireLock(at: path) else {
            Issue.record("expected .acquired for a fresh lock path")
            return
        }
        #expect(fd >= 0)
        close(fd)
    }

    @Test("A second concurrent instance is told the lock is held")
    func secondYields() {
        let path = tempLockPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        guard case .acquired(let firstFD) = SingleInstanceGuard.acquireLock(at: path) else {
            Issue.record("first acquire should succeed"); return
        }
        // While the first still holds it, a second attempt on the same path must report it held —
        // this is the case that the old NSRunningApplication scan missed during launch (#109).
        #expect(SingleInstanceGuard.acquireLock(at: path) == .heldByOther)
        close(firstFD)
    }

    @Test("Releasing the lock lets the next instance acquire it (crash-recovery relaunch)")
    func reacquireAfterRelease() {
        let path = tempLockPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        guard case .acquired(let firstFD) = SingleInstanceGuard.acquireLock(at: path) else {
            Issue.record("first acquire should succeed"); return
        }
        // Closing the fd releases the kernel lock — exactly what happens when a holder exits/crashes.
        close(firstFD)

        guard case .acquired(let secondFD) = SingleInstanceGuard.acquireLock(at: path) else {
            Issue.record("a released lock must be re-acquirable"); return
        }
        #expect(secondFD >= 0)
        close(secondFD)
    }

    @Test("An unopenable lock path fails open (proceed unguarded, never wedge shut)")
    func unopenablePathFailsOpen() {
        // Parent directory does not exist, so open(O_CREAT) fails — the guard must not block launch.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-dir-\(UUID().uuidString)/instance.lock")
            .path
        #expect(SingleInstanceGuard.acquireLock(at: path) == .unavailable)
    }
}
