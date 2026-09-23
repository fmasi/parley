import Testing
@testable import TranscriberCore

/// #220 code-council findings, each pinned: the tap must be rebuilt after a grant, the alarm must
/// keep going while the problem lasts, "restored" must mean real audio, and nothing may loop.
struct TapPermissionGuardTests {
    private let zeros = [Int16](repeating: 0, count: 4_800)          // 0.1 s at 48 kHz
    private let audio = [Int16](repeating: 0, count: 4_799) + [1]

    /// Feed `seconds` of exact zeros at 48 kHz, returning every action produced.
    private func feedZeros(_ g: inout TapPermissionGuard, seconds: Double, from start: Double) -> [TapPermissionGuard.Action] {
        var actions: [TapPermissionGuard.Action] = []
        var t = start
        for _ in 0..<Int(seconds * 10) {
            actions += g.samples(zeros, rate: 48_000, now: t)
            t += 0.1
        }
        return actions
    }

    // MARK: - The critical council finding: grant after a build without it

    /// Permission undetermined at Record → the prompt → the user clicks Allow within seconds. The tap
    /// built before the answer keeps delivering zeros; the guard MUST rebuild it.
    @Test func grantAfterBuildingWithoutItRebuildsTheTap() {
        var g = TapPermissionGuard()
        #expect(g.tapBuilt(status: .notDetermined, now: 0) == [])
        #expect(g.tick(now: 1) == [.checkPermission(.none)])
        #expect(g.permissionChecked(.authorized, evidence: .none, now: 1) == [.rebuildTap])
    }

    @Test func denialAtBuildIsReportedOnTheFirstTick() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .denied, now: 0)
        #expect(g.tick(now: 1) == [.checkPermission(.none)])
        #expect(g.permissionChecked(.denied, evidence: .none, now: 1) == [.reportDenied(.denied)])
    }

    @Test func undeterminedIsNotReportedWhileThePromptCanStillBeAnswered() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .notDetermined, now: 0)
        _ = g.tick(now: 1)
        #expect(g.permissionChecked(.notDetermined, evidence: .none, now: 1) == [])
        _ = g.tick(now: 21)
        #expect(g.permissionChecked(.notDetermined, evidence: .none, now: 21) == [.reportDenied(.notDetermined)])
    }

    // MARK: - Keeps telling you

    @Test func persistingDenialIsReReportedEveryMinute() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .denied, now: 0)
        _ = g.tick(now: 1)
        #expect(g.permissionChecked(.denied, evidence: .none, now: 1) == [.reportDenied(.denied)])
        // Re-checked every 5 s, but not re-reported until a minute has passed.
        _ = g.tick(now: 6)
        #expect(g.permissionChecked(.denied, evidence: .none, now: 6) == [])
        _ = g.tick(now: 61)
        #expect(g.permissionChecked(.denied, evidence: .none, now: 61) == [.reportDenied(.denied)])
    }

    /// Dismissing the repair window and fixing the permission in System Settings must still rebuild.
    @Test func grantDiscoveredByTheRecheckRebuildsWithoutTheApp() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .denied, now: 0)
        _ = g.tick(now: 1)
        _ = g.permissionChecked(.denied, evidence: .none, now: 1)
        #expect(g.tick(now: 6) == [.checkPermission(.none)])
        #expect(g.permissionChecked(.authorized, evidence: .none, now: 6) == [.rebuildTap])
    }

    @Test func checksAreThrottledToTheRecheckInterval() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .denied, now: 0)
        _ = g.tick(now: 1)
        _ = g.permissionChecked(.denied, evidence: .none, now: 1)
        #expect(g.tick(now: 2) == [])
        #expect(g.tick(now: 5.9) == [])
        #expect(g.tick(now: 6) == [.checkPermission(.none)])
    }

    @Test func noConcurrentChecks() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .denied, now: 0)
        #expect(g.tick(now: 10) == [.checkPermission(.none)])
        #expect(g.deliveryGap(now: 11) == [])   // the first check hasn't answered yet
    }

    // MARK: - Not paranoid

    @Test func grantedTapDoesNothingOnTicks() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .authorized, now: 0)
        #expect(g.tick(now: 1) == [])
        #expect(g.tick(now: 100) == [])
    }

    // MARK: - "Restored" means real audio

    @Test func restoredOnlyWhenRealAudioArrives() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .denied, now: 0)
        _ = g.tick(now: 1)
        _ = g.permissionChecked(.denied, evidence: .none, now: 1)
        _ = g.tick(now: 6)
        #expect(g.permissionChecked(.authorized, evidence: .none, now: 6) == [.rebuildTap])
        #expect(g.tapBuilt(status: .authorized, now: 6.2) == [])
        #expect(g.samples(zeros, rate: 48_000, now: 6.3) == [])
        #expect(g.samples(audio, rate: 48_000, now: 6.4) == [.reportRestored])
        #expect(g.samples(audio, rate: 48_000, now: 6.5) == [])
    }

    @Test func realAudioClearsABuildWithoutGrant() {
        // TCC may apply a grant without a rebuild; real audio is proof enough.
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .notDetermined, now: 0)
        _ = g.samples(audio, rate: 48_000, now: 0.5)
        #expect(g.builtWithoutGrant == false)
        #expect(g.tick(now: 10) == [])
    }

    // MARK: - Evidence

    @Test func exactZeroRunTriggersACheckNotAnAlarm() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .authorized, now: 0)
        let actions = feedZeros(&g, seconds: 12.5, from: 0)
        #expect(actions == [.checkPermission(.exactZeroRun)])
    }

    @Test func zeroRunWithDenialReports() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .authorized, now: 0)   // stale TCC cache said fine
        _ = feedZeros(&g, seconds: 12.5, from: 0)
        #expect(g.permissionChecked(.denied, evidence: .exactZeroRun, now: 13) == [.reportDenied(.denied)])
    }

    /// Granted but silent: one insurance rebuild per episode, never a loop.
    @Test func grantedSilenceGetsOneInsuranceRebuildPerEpisode() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .authorized, now: 0)
        _ = feedZeros(&g, seconds: 12.5, from: 0)
        #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: 13) == [.rebuildTap])
        _ = g.tapBuilt(status: .authorized, now: 13.2)
        _ = feedZeros(&g, seconds: 12.5, from: 13.3)
        #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: 26) == [])
        // Real audio re-arms it for the next silence.
        _ = g.samples(audio, rate: 48_000, now: 27)
        _ = feedZeros(&g, seconds: 12.5, from: 28)
        #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: 41) == [.rebuildTap])
    }

    /// #220's rebuilt tap delivered NO buffers for 51 minutes — the zero detector can't see that.
    @Test func deliveryGapTriggersACheck() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .authorized, now: 0)
        #expect(g.deliveryGap(now: 5) == [.checkPermission(.deliveryGap)])
        #expect(g.permissionChecked(.denied, evidence: .deliveryGap, now: 5) == [.reportDenied(.denied)])
    }

    // MARK: - Unverifiable (private SPI gone)

    @Test func unverifiableWithEvidenceReportsButNeverRebuilds() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: nil, now: 0)
        #expect(g.tick(now: 1) == [])   // nothing suspected, nothing to poll
        _ = feedZeros(&g, seconds: 12.5, from: 0)
        #expect(g.permissionChecked(nil, evidence: .exactZeroRun, now: 13) == [.reportDenied(nil)])
        _ = g.tick(now: 18)
        #expect(g.permissionChecked(nil, evidence: .none, now: 18) == [])
    }

    @Test func unverifiableWithoutEvidenceIsSilent() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: nil, now: 0)
        _ = g.deliveryGap(now: 1)
        #expect(g.permissionChecked(nil, evidence: .none, now: 1) == [])
    }

    // MARK: - Provenance facts

    @Test func countsDeliveredAndExactZeroFrames() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .authorized, now: 0)
        _ = g.samples(zeros, rate: 48_000, now: 0)
        _ = g.samples(audio, rate: 48_000, now: 0.1)
        #expect(g.deliveredFrames == 9_600)
        #expect(g.exactZeroFrames == 4_800)
    }

    // MARK: - Council round 2

    /// Fast Allow: nothing was ever reported, so real audio must not announce a "restore".
    @Test func noRestoredMessageWhenNothingWasReported() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .notDetermined, now: 0)
        _ = g.tick(now: 1)
        #expect(g.permissionChecked(.authorized, evidence: .none, now: 1) == [.rebuildTap])
        _ = g.tapBuilt(status: .authorized, now: 1.2)
        #expect(g.samples(audio, rate: 48_000, now: 2) == [])
    }

    /// After a grant rebuild, if silence persists past the one insurance rebuild, say so: "audio or an
    /// alarm, never neither".
    @Test func silenceAfterAGrantRebuildIsReportedAsUnconfirmed() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .notDetermined, now: 0)
        _ = g.tick(now: 1)
        _ = g.permissionChecked(.authorized, evidence: .none, now: 1)
        _ = g.tapBuilt(status: .authorized, now: 1.2)
        _ = feedZeros(&g, seconds: 12.5, from: 1.3)
        #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: 14) == [.rebuildTap])   // insurance
        _ = g.tapBuilt(status: .authorized, now: 14.2)
        _ = feedZeros(&g, seconds: 12.5, from: 14.3)
        #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: 27) == [.reportDenied(nil)])
        // …and real audio then clears it with a restore.
        #expect(g.samples(audio, rate: 48_000, now: 28) == [.reportRestored])
    }

    /// A rebuilt tap that delivers NOTHING while output plays (no samples → no zero run) is evidence too.
    @Test func noBuffersAfterAGrantRebuildWhileOutputPlaysIsEvidence() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .denied, now: 0)
        _ = g.tick(now: 1)
        _ = g.permissionChecked(.denied, evidence: .none, now: 1)
        _ = g.tick(now: 6)
        _ = g.permissionChecked(.authorized, evidence: .none, now: 6)
        _ = g.tapBuilt(status: .authorized, now: 6.2)
        #expect(g.tick(now: 10, outputRunning: true) == [])
        #expect(g.tick(now: 22, outputRunning: false) == [])   // idle output: no buffers is normal (#66)
        #expect(g.tick(now: 22, outputRunning: true) == [.checkPermission(.deliveryGap)])
    }

    /// Unverifiable (SPI gone): report once on evidence, then stop polling a check that can't answer.
    @Test func unverifiableReportDoesNotKeepPolling() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: nil, now: 0)
        _ = feedZeros(&g, seconds: 12.5, from: 0)
        #expect(g.permissionChecked(nil, evidence: .exactZeroRun, now: 13) == [.reportDenied(nil)])
        #expect(g.tick(now: 20) == [])
        #expect(g.tick(now: 100) == [])
    }
}
