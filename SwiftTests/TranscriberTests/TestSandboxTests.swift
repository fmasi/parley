import Testing
import Foundation
@testable import TranscriberCore
import TestHomeGuard

/// #313: a coordinator test once reached a real finalize with `Config.default` — the user's real
/// ~/Documents/Recordings and a 15 h storage limit — and the limit deleted the user's archives.
/// Three guards: the coordinator harness never records into the real folder, the whole test process
/// runs with a throwaway home (`scripts/swift-test.sh`), so `Config.default` itself points somewhere
/// disposable, and the test bundle exits before any test runs when it is not (`TestHomeGuard`).
@MainActor
struct TestSandboxTests {
    @Test("the coordinator harness records into its own temp folder, with a limit that deletes nothing")
    func harnessNeverUsesTheRealFolder() throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.config.config.recordingDirectory.hasPrefix(h.tmp.path))
        #expect(h.config.config.audioArchiveLimitHours >= 100_000)
    }

    @Test("the test process runs with a throwaway home, not the user's")
    func theHomeIsNotTheUsersHome() throws {
        let real = try #require(getpwuid(getuid())).pointee.pw_dir.map { String(cString: $0) }
        let home = (NSHomeDirectory() as NSString).resolvingSymlinksInPath
        #expect(home != real.map { ($0 as NSString).resolvingSymlinksInPath },
                "run the tests through `bash scripts/swift-test.sh` or `just test`")
        #expect(!Config.default.recordingDirectory.hasPrefix((real ?? "/nonexistent") + "/"))
    }

    @Test("the home guard ran before any test and found a throwaway home")
    func theProcessWideGuardIsLinkedAndPassed() {
        // 0 would mean the guard's constructor never ran: a bare `swift test` would then reach the real home.
        #expect(parley_test_home_guard_passed() == 1)
    }
}
