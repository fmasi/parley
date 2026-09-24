import Dispatch
import Foundation
import os
import Testing
@testable import TranscriberCore

/// H2 council (B-I1/I2/I3) + round 2: the helper's session claim. A start reserves the session before
/// it builds anything, under a token; a stop or disconnect during the start aborts it and is answered
/// only once the start has torn down; a start that hangs is abandoned at its own deadline; a stop always
/// ends idle; a rotation during a start or a stop, or into another session, gets a reply that is NOT the
/// dead-capture one.
@Suite struct CaptureLifecycleTests {
    typealias Lifecycle = CaptureLifecycle<String>

    @Test func aSecondStartWhileStartingOrCapturingIsRefused() throws {
        var l = Lifecycle()
        let claim = l.claimStart()
        let first = try #require(claim)
        let second = l.claimStart()
        let committed = l.commitStart(first)
        let third = l.claimStart()
        #expect(second == nil, "a start in flight is a claim, not only a check")
        #expect(committed)
        #expect(third == nil, "capturing")
    }

    @Test func eachStartGetsANewToken() throws {
        var l = Lifecycle()
        let claimA = l.claimStart()
        let a = try #require(claimA)
        _ = l.startEnded(a)
        let claimB = l.claimStart()
        let b = try #require(claimB)
        #expect(a != b)
    }

    /// Round 2 item 4: the stop is answered only by the start's teardown, never before it.
    @Test func aStopDuringAStartIsAnsweredOnlyWhenTheStartHasTornDown() throws {
        var l = Lifecycle()
        let claim = l.claimStart()
        let t = try #require(claim)
        let stop = l.requestStop("stop-1")
        #expect(stop == .abortStart)
        #expect(l.isStopping, "the start's commit-or-abort guards see the stop")
        #expect(!l.startMayProceed(t), "no further step opens anything (round 2 item 9)")
        #expect(!l.isCapturing)
        let committed = l.commitStart(t)
        #expect(!committed, "the aborted start never commits")
        #expect(l.phase == .starting, "still starting until it has torn down what it built")
        let owns = l.beginEndingStart(t)
        #expect(owns)
        let answered = l.startEnded(t)
        #expect(answered == ["stop-1"], "the waiting stop comes back with the teardown's end")
        #expect(l.phase == .idle)
        #expect(!l.isStopping)
        let next = l.claimStart()
        #expect(next != nil, "nothing left behind")
    }

    @Test func aDisconnectDuringAStartIsTheSameAbort() throws {
        var l = Lifecycle()
        let claim = l.claimStart()
        let t = try #require(claim)
        let stop = l.requestStop("stop")
        let disconnect = l.requestStop("disconnect")
        let committed = l.commitStart(t)
        #expect(stop == .abortStart)
        #expect(disconnect == .abortStart, "a second stop joins the same abort")
        #expect(!committed)
        let answered = l.startEnded(t)
        #expect(answered == ["stop", "disconnect"])
    }

    /// Round 2 item 1: a start stuck in the OS (the mic's `startRunning` on a HAL lock) must not keep
    /// the reservation. Its deadline wins the ending; the stuck start, when it finally returns, loses it.
    @Test func aTimedOutStartReleasesTheClaimAndItsWaitingStops() throws {
        var l = Lifecycle()
        let claim = l.claimStart()
        let t = try #require(claim)
        _ = l.requestStop("stop")
        let deadlineWins = l.beginEndingStart(t)
        #expect(deadlineWins)
        #expect(!l.startMayProceed(t), "the stuck start bails at its next step")
        #expect(l.isStopping, "its commit-or-abort guards tear down what it opens late")
        let lateFailureWins = l.beginEndingStart(t)
        #expect(!lateFailureWins, "one ending per start: no double teardown, no double reply")
        let answered = l.startEnded(t)
        #expect(answered == ["stop"])
        let claimNext = l.claimStart()
        let next = try #require(claimNext, "the next Record is allowed")
        let staleCommit = l.commitStart(t)
        #expect(!staleCommit, "the stale start can never commit into the new session")
        let staleEnd = l.startEnded(t)
        #expect(staleEnd.isEmpty, "nor end it")
        #expect(l.phase == .starting && l.startMayProceed(next))
    }

    @Test func theStartDeadlineOutlastsTheAppsStartDeadline() {
        #expect(Lifecycle.startTimeoutSeconds == 20)
        #expect(Lifecycle.sourceStopTimeoutSeconds == 3)
    }

    @Test func aStopAlwaysEndsIdleSoTheNextRecordIsNeverRefused() throws {
        var l = Lifecycle()
        let claim = l.claimStart()
        let t = try #require(claim)
        _ = l.commitStart(t)
        let stop = l.requestStop("a")
        #expect(stop == .stop)
        #expect(l.isStopping && l.isCapturing, "files not sealed yet: status still says capturing")
        #expect(!l.isLive, "no live-session work once stopping")
        let duplicate = l.requestStop("b")
        #expect(duplicate == .alreadyStopping, "a duplicate stop is not a second teardown")
        l.stopEnded()
        #expect(l.phase == .idle)
        let next = l.claimStart()
        #expect(next != nil)
    }

    @Test func aFailedStartReleasesTheClaim() throws {
        var l = Lifecycle()
        let claim = l.claimStart()
        let t = try #require(claim)
        let owns = l.beginEndingStart(t)
        #expect(owns)
        let answered = l.startEnded(t)
        #expect(answered.isEmpty)
        let next = l.claimStart()
        #expect(next != nil)
    }

    @Test func aStopWithNothingRunningIsNotCapturing() {
        var l = Lifecycle()
        let stop = l.requestStop("x")
        #expect(stop == .notCapturing)
        #expect(l.phase == .idle)
    }

    /// B-I3 + §8.7: "No capture in progress" on a rotate is the app's dead-capture signal, so a
    /// rotation that merely lands in a start or a stop must get a different reply.
    @Test func rotationIsRefusedWhileStartingOrStoppingWithoutLookingDead() throws {
        var l = Lifecycle()
        #expect(l.rotationGate == .notCapturing)
        let claim = l.claimStart()
        let t = try #require(claim)
        #expect(l.rotationGate == .refusedStopping)
        _ = l.commitStart(t)
        #expect(l.rotationGate == .allowed)
        _ = l.requestStop("s")
        #expect(l.rotationGate == .refusedStopping)
        l.stopEnded()
        #expect(l.rotationGate == .notCapturing)
    }

    /// Round 2 item 10: the re-check compares the SESSION, not the phase. A stop and a new start between
    /// the rotate's first check and its swap leave the phase `capturing` again — in another session.
    @Test func aRotationChecksItsOwnSessionNotJustThePhase() throws {
        var l = Lifecycle()
        let claimFirst = l.claimStart()
        let first = try #require(claimFirst)
        _ = l.commitStart(first)
        #expect(l.allowsRotation(of: first))
        _ = l.requestStop("s")
        l.stopEnded()
        let claimSecond = l.claimStart()
        let second = try #require(claimSecond)
        _ = l.commitStart(second)
        #expect(!l.allowsRotation(of: first))
        #expect(l.allowsRotation(of: second))
    }

    @Test func startAndStopEndingOutOfPhaseChangeNothing() throws {
        var l = Lifecycle()
        let claim = l.claimStart()
        let t = try #require(claim)
        _ = l.commitStart(t)
        let owns = l.beginEndingStart(t)
        #expect(!owns)
        let answered = l.startEnded(t)
        #expect(answered.isEmpty)
        #expect(l.phase == .capturing, "a late start teardown cannot end a committed capture")
        l.stopEnded()
        #expect(l.phase == .capturing, "only a stop in progress ends")
    }

    /// The app matches the rotate reply with `contains("No capture in progress")` to take the crash
    /// path (§8.7): no other reply may match it. Every reply the app acts on is a constant.
    @Test func theRepliesAreDistinctAndNoneLooksLikeTheDeadCaptureReply() {
        #expect(CaptureReplies.noCaptureInProgress == "No capture in progress", "the string the app has always matched")
        #expect(CaptureReplies.alreadyInProgress == "Capture already in progress", "the string the app has always matched")
        let others = [CaptureReplies.refusedStopping, CaptureReplies.alreadyInProgress, CaptureReplies.startCancelled,
                      CaptureReplies.startTimedOut, CaptureReplies.cancelledWhileStarting]
        #expect(Set(others + [CaptureReplies.noCaptureInProgress]).count == 6)
        #expect(others.allSatisfy { !$0.contains(CaptureReplies.noCaptureInProgress) && !$0.isEmpty })
    }
}

/// Round 2 item 4 (IMPORTANT): the headline ordering of a stop, pinned. The WAVs are sealed before any
/// source is asked to stop; both sources stop concurrently under ONE bound; the session ends even when
/// a stop never returns (M-C, gotcha #68).
@Suite struct StopSequenceTests {
    final class Log: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[String]>(initialState: [])
        func add(_ s: String) { lock.withLock { $0.append(s) } }
        var entries: [String] { lock.withLock { $0 } }
    }

    @Test func theFilesAreSealedBeforeAnySourceStopsAndTheSessionEndsLast() {
        let log = Log()
        let outcome = StopSequence.run(
            seal: { log.add("seal") },
            stopMic: { log.add("mic") }, stopTap: { log.add("tap") },
            timeout: 2, end: { log.add("end") })
        #expect(log.entries.first == "seal")
        #expect(log.entries.last == "end")
        #expect(Set(log.entries.dropFirst().dropLast()) == ["mic", "tap"])
        #expect(outcome == StopSequence.Outcome(micAbandoned: false, tapAbandoned: false))
    }

    @Test func theSessionEndsEvenWhenAStopNeverReturns() {
        let log = Log()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let start = DispatchTime.now()
        let outcome = StopSequence.run(
            seal: { log.add("seal") },
            stopMic: { release.wait() }, stopTap: nil,
            timeout: 0.2, end: { log.add("end") })
        let waited = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        #expect(log.entries == ["seal", "end"])
        #expect(outcome.micAbandoned && !outcome.tapAbandoned)
        #expect(waited < 1.5, "bounded")
    }

    /// Two stuck sources cost ONE bound, not two: they stop concurrently.
    @Test func bothSourcesStopConcurrentlyUnderOneBound() {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let start = DispatchTime.now()
        let outcome = StopSequence.run(
            seal: {}, stopMic: { release.wait() }, stopTap: { release.wait() },
            timeout: 0.3, end: {})
        let waited = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        #expect(outcome.micAbandoned && outcome.tapAbandoned)
        #expect(waited < 0.55, "one 0.3 s bound for both, not 0.6 s")
    }

    @Test func twoSlowButFinishingStopsBothFinishWithinOneBound() {
        let outcome = StopSequence.run(
            seal: {}, stopMic: { Thread.sleep(forTimeInterval: 0.2) }, stopTap: { Thread.sleep(forTimeInterval: 0.2) },
            timeout: 1.5, end: {})
        #expect(!outcome.micAbandoned && !outcome.tapAbandoned)
    }
}

/// Round 2 item 1: an XPC reply block must be called exactly once, whichever of the start's deadline
/// and its own (late) completion gets there first.
@Suite struct OnceFlagTests {
    @Test func onlyTheFirstClaimWins() {
        let once = OnceFlag()
        #expect(once.claim())
        #expect(!once.claim())
        #expect(!once.claim())
    }

    @Test func concurrentClaimsHaveExactlyOneWinner() {
        let once = OnceFlag()
        let wins = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if once.claim() { wins.withLock { $0 += 1 } }
        }
        #expect(wins.withLock { $0 } == 1)
    }
}
