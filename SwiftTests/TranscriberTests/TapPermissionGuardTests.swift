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
        #expect(g.permissionChecked(.authorized, evidence: .none, now: 1) == [.rebuildTap(reason: .grant)])
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
        #expect(g.permissionChecked(.authorized, evidence: .none, now: 6) == [.rebuildTap(reason: .grant)])
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
        #expect(feedZeros(&g, seconds: 13, from: 11).isEmpty)   // the first check hasn't answered yet
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
        #expect(g.permissionChecked(.authorized, evidence: .none, now: 6) == [.rebuildTap(reason: .grant)])
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
        #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: 13) == [.rebuildTap(reason: .insurance)])
        _ = g.tapBuilt(status: .authorized, now: 13.2)
        _ = feedZeros(&g, seconds: 12.5, from: 13.3)
        #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: 26) == [])
        // Real audio proves the grant: the next silence on that tap is silence, with no rebuild (#333 R2)…
        _ = g.samples(audio, rate: 48_000, now: 27)
        _ = feedZeros(&g, seconds: 12.5, from: 28)
        #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: 41) == [])
        // …and it still re-arms the insurance, for a tap rebuilt later without a confirmed grant.
        _ = g.tapBuilt(status: nil, now: 42)
        _ = feedZeros(&g, seconds: 12.5, from: 42.1)
        #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: 55) == [.rebuildTap(reason: .insurance)])
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
        #expect(g.permissionChecked(.authorized, evidence: .none, now: 1) == [.rebuildTap(reason: .grant)])
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
        #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: 14) == [.rebuildTap(reason: .insurance)])
        _ = g.tapBuilt(status: .authorized, now: 14.2)
        _ = feedZeros(&g, seconds: 12.5, from: 14.3)
        #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: 27) == [.reportDenied(nil)])
        // …and real audio then clears it with a restore.
        #expect(g.samples(audio, rate: 48_000, now: 28) == [.reportRestored])
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

    // MARK: - Grant proven (#333): a tap that has delivered real audio was granted access

    /// R1. coreaudiod decides a tap's access when its IO starts (gotcha #70), so non-zero audio is the
    /// one proof that this tap has the grant. An `authorized` answer is not: TCC's answer can be stale.
    @Test func realAudioProvesTheGrant() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .authorized, now: 0)
        #expect(!g.grantProven, "an authorized answer alone proves nothing")
        _ = g.samples(zeros, rate: 48_000, now: 0.1)
        #expect(!g.grantProven)
        _ = g.samples(audio, rate: 48_000, now: 0.2)
        #expect(g.grantProven)
        _ = g.samples(zeros, rate: 48_000, now: 0.3)
        #expect(g.grantProven, "zeros after real audio are silence")
    }

    /// R1: the proof is the TAP's. A rebuild keeps it only with a fresh `authorized` answer; a denied,
    /// undetermined or unverifiable build is a new tap nobody vouched for.
    @Test func theProofSurvivesARebuildOnlyWithAnAuthorizedAnswer() {
        for status in [PermissionStatus.denied, .notDetermined, nil] {
            var g = TapPermissionGuard()
            _ = g.tapBuilt(status: .authorized, now: 0)
            _ = g.samples(audio, rate: 48_000, now: 0.5)
            _ = g.tapBuilt(status: .authorized, now: 5)
            #expect(g.grantProven, "rebuilt with the grant confirmed")
            _ = g.tapBuilt(status: status, now: 10)
            #expect(!g.grantProven, "rebuilt with \(String(describing: status))")
            _ = g.samples(audio, rate: 48_000, now: 10.5)
            #expect(g.grantProven, "real audio proves the new tap too")
        }
    }

    /// R1: any answer but `authorized` withdraws the proof, whatever the check was asked for.
    @Test func anyAnswerButAuthorizedWithdrawsTheProof() {
        for status in [PermissionStatus.denied, .notDetermined, nil] {
            for evidence in [TapPermissionGuard.Evidence.none, .exactZeroRun] {
                var g = TapPermissionGuard()
                _ = g.tapBuilt(status: .authorized, now: 0)
                _ = g.samples(audio, rate: 48_000, now: 0.5)
                _ = g.permissionChecked(.authorized, evidence: evidence, now: 1)
                #expect(g.grantProven, "an authorized answer keeps it")
                _ = g.permissionChecked(status, evidence: evidence, now: 2)
                #expect(!g.grantProven, "\(String(describing: status)), \(evidence)")
            }
        }
    }

    /// R2, the false recovery (2026-10-09: an insurance rebuild 12 s after the hang-up, and a 1–2 s
    /// AirPods dropout from another): a remote that goes quiet for 12 s after it has spoken gets the
    /// permission check, which is the only mid-call revocation detector, and no rebuild. Every time.
    @Test func aMutedRemoteOnAProvenTapGetsTheCheckAndNoRebuild() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .authorized, now: 0)
        _ = g.samples(audio, rate: 48_000, now: 0.5)
        var t = 1.0
        for _ in 0..<3 {
            #expect(feedZeros(&g, seconds: 12.5, from: t) == [.checkPermission(.exactZeroRun)])
            #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: t + 13) == [])
            #expect(g.samples(audio, rate: 48_000, now: t + 14) == [], "nothing was reported: nothing to restore")
            t += 15
        }
    }

    /// R2 must not weaken a revocation: on a proven tap a `denied` answer is reported, the grant
    /// rebuild runs when the permission comes back, and silence after it is unproven again, so it
    /// gets the insurance rebuild and then "can't confirm", as before.
    @Test func aRevocationOnAProvenTapIsReportedAndHealedAsBefore() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .authorized, now: 0)
        _ = g.samples(audio, rate: 48_000, now: 0.5)
        _ = feedZeros(&g, seconds: 12.5, from: 1)
        #expect(g.permissionChecked(.denied, evidence: .exactZeroRun, now: 14) == [.reportDenied(.denied)])
        #expect(g.tick(now: 19) == [.checkPermission(.none)])
        #expect(g.permissionChecked(.authorized, evidence: .none, now: 19) == [.rebuildTap(reason: .grant)])
        _ = g.tapBuilt(status: .authorized, now: 19.2)
        _ = feedZeros(&g, seconds: 12.5, from: 19.3)
        #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: 32) == [.rebuildTap(reason: .insurance)])
        _ = g.tapBuilt(status: .authorized, now: 32.2)
        _ = feedZeros(&g, seconds: 12.5, from: 32.3)
        #expect(g.permissionChecked(.authorized, evidence: .exactZeroRun, now: 45) == [.reportDenied(nil)])
        #expect(g.samples(audio, rate: 48_000, now: 46) == [.reportRestored])
        #expect(g.grantProven)
    }

    /// R2 on a proven tap changes nothing about the other answers to a zero run.
    @Test func aProvenTapStillReportsAnUndeterminedOrUnverifiableAnswerToAZeroRun() {
        for status in [PermissionStatus.notDetermined, nil] {
            var g = TapPermissionGuard()
            _ = g.tapBuilt(status: .authorized, now: 0)
            _ = g.samples(audio, rate: 48_000, now: 0.5)
            _ = feedZeros(&g, seconds: 12.5, from: 1)
            #expect(g.permissionChecked(status, evidence: .exactZeroRun, now: 14) == [.reportDenied(status)])
        }
    }

    // MARK: - Unproven zeros (#333 R3)

    /// The record separates silence on a proven tap from zeros nobody can vouch for: the frames
    /// before the first real audio, and the frames after a denial or an unconfirmed rebuild.
    @Test func zerosAreCountedAsUnprovenWhileTheGrantIsNotProven() {
        var g = TapPermissionGuard()
        _ = g.tapBuilt(status: .authorized, now: 0)
        _ = g.samples(zeros, rate: 48_000, now: 0)
        _ = g.samples(zeros, rate: 48_000, now: 0.1)
        #expect(g.unprovenZeroFrames == 9_600 && g.exactZeroFrames == 9_600, "zeros from the first frame: #220's shape")
        _ = g.samples(audio, rate: 48_000, now: 0.2)
        for i in 0..<3 { _ = g.samples(zeros, rate: 48_000, now: 0.3 + Double(i) / 10) }
        #expect(g.unprovenZeroFrames == 9_600 && g.exactZeroFrames == 24_000, "silence on a proven tap")
        _ = g.permissionChecked(.denied, evidence: .none, now: 1)
        _ = g.samples(zeros, rate: 48_000, now: 1.1)
        #expect(g.unprovenZeroFrames == 14_400 && g.exactZeroFrames == 28_800, "after a denial zeros are unproven again")
        _ = g.samples(audio, rate: 48_000, now: 1.2)
        _ = g.tapBuilt(status: nil, now: 2)
        _ = g.samples(zeros, rate: 48_000, now: 2.1)
        #expect(g.unprovenZeroFrames == 19_200 && g.exactZeroFrames == 33_600, "and after a rebuild nobody could verify")
        #expect(g.deliveredFrames == 43_200)
    }
}
