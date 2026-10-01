import Testing
@testable import TranscriberCore

/// §9 / M-A: exact zeros with the permission authorized are the muted-remote shape and never alarm
/// on their own. A "can't confirm" after a long run ships OFF (nil) until the exact-zero census
/// shows no call app renders zeros when muted. Time is continuous across feeds (scan B P1.3).
@Suite struct TapPermissionGuardSoftAlarmTests {
    private let zeros = [Int16](repeating: 0, count: 4_800)

    /// Feeds 0.1 s batches of zeros from `from` for `seconds`; returns the actions and the end time.
    private func feed(_ g: inout TapPermissionGuard, seconds: Double, from: Double) -> (actions: [TapPermissionGuard.Action], end: Double) {
        var actions: [TapPermissionGuard.Action] = []
        var t = from
        for _ in 0..<Int(seconds * 10) {
            actions += g.samples(zeros, rate: 48_000, now: t)
            actions += g.tick(now: t)
            t += 0.1
        }
        return (actions, t)
    }

    /// The grey zone end to end: check once, one insurance rebuild, then nothing for ten minutes.
    @Test func offByDefaultTenMinutesOfZerosNeverAlarms() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .authorized, now: 0)
        let first = feed(&g, seconds: 13, from: 0)
        #expect(first.actions.filter { $0 == .checkPermission(.exactZeroRun) }.count == 1)
        #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: first.end) == [.rebuildTap(reason: .insurance)])
        _ = g.tapBuilt(status: .authorized, now: first.end)
        let rest = feed(&g, seconds: 600, from: first.end)
        #expect(!rest.actions.contains { if case .reportDenied = $0 { return true }; return false })
        #expect(!rest.actions.contains { if case .rebuildTap = $0 { return true }; return false }, "one insurance rebuild per episode")
    }

    @Test func whenEnabledItSaysCantConfirmOnceAfterTheWindow() {
        var g = TapPermissionGuard(softAlarmSeconds: 300)
        _ = g.tapBuilt(status: .authorized, now: 0)
        let before = feed(&g, seconds: 299, from: 0)
        #expect(!before.actions.contains(.reportDenied(nil)))
        let after = feed(&g, seconds: 2, from: before.end)
        #expect(after.actions.filter { $0 == .reportDenied(nil) }.count == 1)
    }

    @Test func realAudioResetsTheSoftWindow() {
        var g = TapPermissionGuard(softAlarmSeconds: 300)
        _ = g.tapBuilt(status: .authorized, now: 0)
        let first = feed(&g, seconds: 200, from: 0)
        _ = g.samples([Int16](repeating: 0, count: 4_799) + [1], rate: 48_000, now: first.end)
        let second = feed(&g, seconds: 200, from: first.end + 0.1)
        #expect(!second.actions.contains(.reportDenied(nil)), "400 s of zeros in total, but only 200 s since real audio")
    }
}
