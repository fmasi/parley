import Testing
@testable import TranscriberCore

/// Fix round 2, item 2 (design correction for `LaunchAgentManager.handOverToJob`): "kickstart then
/// yield" left NO instance running, since the launchd-spawned copy (B) yielded on seeing A's lock
/// still held. B must WAIT for the lock instead.
@Suite struct SingleInstancePolicyTests {
    @Test func lockFreeAlwaysProceeds() {
        #expect(SingleInstancePolicy.decide(isLaunchdJob: false, lockHeldByOther: false) == .proceed)
        #expect(SingleInstancePolicy.decide(isLaunchdJob: true, lockHeldByOther: false) == .proceed)
    }

    @Test func anOrdinaryDuplicateLaunchYieldsWhenTheLockIsHeld() {
        #expect(SingleInstancePolicy.decide(isLaunchdJob: false, lockHeldByOther: true) == .yield)
    }

    /// The hand-over protocol: B is the launchd-spawned copy — it must wait for A to release the
    /// lock, not yield (yielding here would leave zero instances running).
    @Test func theLaunchdJobWaitsForTheLockInsteadOfYielding() {
        #expect(SingleInstancePolicy.decide(isLaunchdJob: true, lockHeldByOther: true) == .waitForLock(seconds: SingleInstancePolicy.lockWaitTimeout, onTimeout: .exitZero))
    }

    @Test func theWaitTimeoutIsTenSeconds() {
        #expect(SingleInstancePolicy.lockWaitTimeout == 10)
    }

    /// Fix round 3, item 1 [Important]: the timeout outcome was unspecified, and launchd starts the
    /// job at EVERY bootstrap (runs=1, minimum runtime=10 — see launchctl-print-live.txt), so B hits
    /// this timeout whenever a Finder-launched instance repairs at launch and then does not hand
    /// over (recording, or inside the cooldown). Exiting non-zero would make KeepAlive respawn B
    /// roughly every 10s (a relaunch loop); proceeding would leave two instances. `.exitZero` is
    /// the only outcome the type allows — it's baked into the case, not left for the caller to
    /// guess.
    @Test func theWaitTimeoutOutcomeIsAlwaysExitZeroNeverNonZeroNeverProceed() {
        guard case .waitForLock(_, let onTimeout) = SingleInstancePolicy.decide(isLaunchdJob: true, lockHeldByOther: true) else {
            Issue.record("expected .waitForLock")
            return
        }
        #expect(onTimeout == .exitZero)
    }
}
