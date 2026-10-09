import Testing
import Foundation
@testable import TranscriberCore

/// #313: a coordinator test once reached a real finalize with `Config.default` — the user's real
/// ~/Documents/Recordings and a 15 h storage limit — and the limit deleted the user's archives.
/// Two guards: the coordinator harness never records into the real folder, and the whole test
/// process runs with a throwaway home (`scripts/test-home.sh`), so `Config.default` itself points
/// somewhere disposable.
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
                "run the tests through `just test` (or set CFFIXED_USER_HOME=$(bash scripts/test-home.sh))")
        #expect(!Config.default.recordingDirectory.hasPrefix((real ?? "/nonexistent") + "/"))
    }
}
