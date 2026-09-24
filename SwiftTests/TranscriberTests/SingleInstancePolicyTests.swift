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
        #expect(SingleInstancePolicy.decide(isLaunchdJob: true, lockHeldByOther: true) == .waitForLock(seconds: SingleInstancePolicy.lockWaitTimeout))
    }

    @Test func theWaitTimeoutIsTenSeconds() {
        #expect(SingleInstancePolicy.lockWaitTimeout == 10)
    }
}
