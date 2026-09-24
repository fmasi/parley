import Foundation
import Testing
@testable import TranscriberCore

/// L1/L3 (§8.3): an app crash mid-meeting used to end the recording silently (the helper stops
/// on disconnect; Flow B salvaged and showed a rename dialog). A stale-sentinel check based on
/// `systemUptime` judged 7.2 h of sleep as "before the last boot".
@Suite struct RelaunchDecisionTests {
    let now = Date(timeIntervalSince1970: 10_000)

    private func decide(alive: TimeInterval?, boot: String? = "B1", stopping: Bool = false,
                        helper: Bool = false, current: String? = "B1", folder: Bool = true) -> RelaunchDecision {
        RelaunchDecision.decide(lastAliveAt: alive.map { now.addingTimeInterval(-$0) }, bootSessionUUID: boot,
                                wasStopping: stopping, now: now, helperCapturing: helper,
                                currentBootSessionUUID: current, folderReachable: folder)
    }

    @Test func helperStillCapturingReattaches() {
        #expect(decide(alive: 30, helper: true) == .reattach)
    }
    @Test func freshSentinelAndDeadHelperResumesTheSameSession() {
        #expect(decide(alive: 30) == .resumeSameSession(gapStart: now.addingTimeInterval(-30)))
    }
    /// Fix round 1, item 8: spec §8.3 says "< 180 s" — the boundary itself does NOT resume.
    @Test func theWindowEdgeIsExclusive() {
        #expect(decide(alive: RelaunchDecision.resumeWindow) == .salvageAndStop(reason: .tooOld(seconds: RelaunchDecision.resumeWindow)))
        let justInside = RelaunchDecision.resumeWindow - 0.1
        #expect(decide(alive: justInside) == .resumeSameSession(gapStart: now.addingTimeInterval(-justInside)))
    }
    @Test func oldSentinelSalvagesAndStops() {
        #expect(decide(alive: 600) == .salvageAndStop(reason: .tooOld(seconds: 600)))
    }
    @Test func aSentinelWithoutLivenessSalvages() {
        #expect(decide(alive: nil) == .salvageAndStop(reason: .noLiveness))
    }
    /// Fix round 1, item 9: a wall-clock jump backwards after `lastAliveAt` was written must not
    /// be read as "very fresh" — a negative age is exactly as untrustworthy as no liveness at all.
    @Test func negativeAgeFromClockSkewSalvagesAsNoLiveness() {
        #expect(decide(alive: -50) == .salvageAndStop(reason: .noLiveness))
    }
    /// Spec §8.3/§8.8 (scan A163/C16): a crash during post-Stop finalize must not resume a recording
    /// the user stopped; the sentinel is marked `stopping` before finalize and that wins over freshness.
    @Test func aSentinelMarkedStoppingIsSalvagedNeverResumed() {
        #expect(decide(alive: 5, stopping: true) == .salvageAndStop(reason: .wasStopping))
    }
    /// Fix round 1, item 7: `stopping` must win over `helperCapturing` too — a stop-in-flight race
    /// where the helper hasn't reported dead yet must never resume the recording the user stopped.
    @Test func stoppingWinsEvenWhenTheHelperStillReportsCapturing() {
        #expect(decide(alive: 5, stopping: true, helper: true) == .salvageAndStop(reason: .wasStopping))
    }
    /// Fix round 2, item 4: round 1 put `wasStopping` ahead of `folderReachable` too, so a stopping
    /// sentinel with an unreachable folder (e.g. an unmounted external drive) salvaged instead of
    /// waiting — L7 would then delete the sentinel off a folder it couldn't actually reach,
    /// breaking "never deletes". `folderReachable` must still gate `wasStopping`'s outcome.
    @Test func stoppingWithAnUnreachableFolderWaitsInsteadOfSalvaging() {
        #expect(decide(alive: 5, stopping: true, folder: false) == .waitForFolder)
    }
    @Test func aDifferentBootSessionIsStaleEvenIfRecent() {
        #expect(decide(alive: 30, boot: "B0") == .salvageStale)
    }
    @Test func unreachableFolderWaitsAndNeverDeletes() {
        #expect(decide(alive: 30, folder: false) == .waitForFolder)
    }
    @Test func unknownBootSessionIsNotStale() {
        #expect(decide(alive: 30, boot: nil) == .resumeSameSession(gapStart: now.addingTimeInterval(-30)))
        #expect(decide(alive: 30, current: nil) == .resumeSameSession(gapStart: now.addingTimeInterval(-30)))
    }
    @Test func thisMachineReportsABootSessionUUID() {
        let uuid = BootSession.currentUUID()
        #expect(uuid?.isEmpty == false)
        #expect(BootSession.currentUUID() == uuid, "stable within one boot")
    }
}
