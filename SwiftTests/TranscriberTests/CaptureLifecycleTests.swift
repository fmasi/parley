import Dispatch
import Testing
@testable import TranscriberCore

/// H2 council (B-I1/I2/I3): the helper's session claim. A start reserves the session before it
/// builds anything; a stop or disconnect during the start aborts it; a stop always ends idle, so the
/// next Record is never refused; a rotation during a start or a stop gets a reply that is NOT the
/// dead-capture one.
@Suite struct CaptureLifecycleTests {
    @Test func aSecondStartWhileStartingOrCapturingIsRefused() {
        var l = CaptureLifecycle()
        let first = l.claimStart()
        let second = l.claimStart()
        let committed = l.commitStart()
        let third = l.claimStart()
        #expect(first)
        #expect(!second, "a start in flight is a claim, not only a check")
        #expect(committed)
        #expect(!third, "capturing")
    }

    @Test func aStopDuringAStartAbortsItAndTheNextStartIsAllowed() {
        var l = CaptureLifecycle()
        _ = l.claimStart()
        let stop = l.requestStop()
        #expect(stop == .abortStart)
        #expect(l.isStopping, "the start's commit-or-abort guards see the stop")
        #expect(!l.isCapturing)
        let committed = l.commitStart()
        #expect(!committed, "the aborted start never commits")
        #expect(l.phase == .starting, "still starting until it has torn down what it built")
        l.startEnded()
        #expect(l.phase == .idle)
        #expect(!l.isStopping)
        let next = l.claimStart()
        #expect(next, "nothing left behind")
    }

    @Test func aDisconnectDuringAStartIsTheSameAbort() {
        var l = CaptureLifecycle()
        _ = l.claimStart()
        let stop = l.requestStop()
        let disconnect = l.requestStop()
        let committed = l.commitStart()
        #expect(stop == .abortStart)
        #expect(disconnect == .abortStart, "a second stop joins the same abort")
        #expect(!committed)
    }

    @Test func aStopAlwaysEndsIdleSoTheNextRecordIsNeverRefused() {
        var l = CaptureLifecycle()
        _ = l.claimStart()
        _ = l.commitStart()
        let stop = l.requestStop()
        #expect(stop == .stop)
        #expect(l.isStopping && l.isCapturing, "files not sealed yet: status still says capturing")
        #expect(!l.isLive, "no live-session work once stopping")
        let duplicate = l.requestStop()
        #expect(duplicate == .alreadyStopping, "a duplicate stop is not a second teardown")
        l.stopEnded()
        #expect(l.phase == .idle)
        let next = l.claimStart()
        #expect(next)
    }

    @Test func aFailedStartReleasesTheClaim() {
        var l = CaptureLifecycle()
        _ = l.claimStart()
        l.startEnded()
        let next = l.claimStart()
        #expect(next)
    }

    @Test func aStopWithNothingRunningIsNotCapturing() {
        var l = CaptureLifecycle()
        let stop = l.requestStop()
        #expect(stop == .notCapturing)
        #expect(l.phase == .idle)
    }

    /// B-I3 + §8.7: "No capture in progress" on a rotate is the app's dead-capture signal, so a
    /// rotation that merely lands in a start or a stop must get a different reply.
    @Test func rotationIsRefusedWhileStartingOrStoppingWithoutLookingDead() {
        var l = CaptureLifecycle()
        #expect(l.rotationGate == .notCapturing)
        _ = l.claimStart()
        #expect(l.rotationGate == .refusedStopping)
        _ = l.commitStart()
        #expect(l.rotationGate == .allowed)
        _ = l.requestStop()
        #expect(l.rotationGate == .refusedStopping)
        l.stopEnded()
        #expect(l.rotationGate == .notCapturing)
    }

    @Test func startAndStopEndingOutOfPhaseChangeNothing() {
        var l = CaptureLifecycle()
        _ = l.claimStart()
        _ = l.commitStart()
        l.startEnded()
        #expect(l.phase == .capturing, "a late start teardown cannot end a committed capture")
        l.stopEnded()
        #expect(l.phase == .capturing, "only a stop in progress ends")
    }

    /// The app matches the rotate reply with `contains("No capture in progress")` to take the crash
    /// path (§8.7): the refused-while-stopping reply must never match it.
    @Test func theStoppingReplyIsNeverTheDeadCaptureReply() {
        #expect(CaptureReplies.noCaptureInProgress == "No capture in progress", "the string the app has always matched")
        #expect(!CaptureReplies.refusedStopping.contains(CaptureReplies.noCaptureInProgress))
        #expect(!CaptureReplies.refusedStopping.isEmpty)
    }
}

/// H2 council (B-I1 / A-I6): a source whose teardown blocks (a rung stuck on the tap's config queue,
/// `AudioDeviceStop` on a paused context, `stopRunning` on a HAL lock) must not hold Stop hostage.
@Suite struct BoundedWaitTests {
    @Test func workThatReturnsInTimeReportsTrue() {
        #expect(BoundedWait.run(seconds: 2) {})
    }

    @Test func blockedWorkIsAbandonedAtTheDeadlineAndStillFinishesLater() {
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let start = DispatchTime.now()
        let inTime = BoundedWait.run(seconds: 0.2) {
            release.wait()
            finished.signal()
        }
        let waited = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        #expect(!inTime)
        #expect(waited < 2, "bounded, not waiting for the work")
        release.signal()
        #expect(finished.wait(timeout: .now() + 2) == .success, "abandoned, not cancelled: it completes on its own")
    }
}
