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

    /// Round 3 (C): every step of a start that installs shared state — the handler and paths, the tap
    /// guard, the healer's target — is guarded by its token, so a start whose deadline fired while it was
    /// blocked can install nothing into the session that follows.
    @Test func aTimedOutStartCannotInstallIntoTheNextSession() throws {
        var l = Lifecycle()
        let claimOld = l.claimStart()
        let old = try #require(claimOld)
        #expect(l.startMayProceed(old), "before its deadline: may install")
        let owns = l.beginEndingStart(old)
        #expect(owns)
        #expect(!l.startMayProceed(old), "after its deadline fired: may not, even mid-teardown")
        _ = l.startEnded(old)
        let claimNew = l.claimStart()
        let new = try #require(claimNew)
        #expect(!l.startMayProceed(old), "nor into the next session")
        #expect(l.startMayProceed(new))
        #expect(l.isCurrentStart(new) && !l.isCurrentStart(old), "whose files it must not delete either")
    }

    // MARK: - Round 5 item 5: a dropped connection stops only the capture it owns

    private final class Connection {}

    /// The app drops a connection on a stop timeout and starts again on a NEW one: the old connection's
    /// late invalidation must not stop the new connection's capture.
    @Test func aDroppedConnectionStopsOnlyTheCaptureItOwns() throws {
        let a = Connection(), b = Connection()
        var l = Lifecycle()
        let claim = l.claimStart(owner: ObjectIdentifier(a))
        let t = try #require(claim)
        _ = l.commitStart(t)
        let fromB = l.requestStop("b", disconnectOf: ObjectIdentifier(b))
        #expect(fromB == .notOwner)
        #expect(l.phase == .capturing, "untouched")
        let fromA = l.requestStop("a", disconnectOf: ObjectIdentifier(a))
        #expect(fromA == .stop)
    }

    /// A start in flight when its own connection drops is aborted — never committed with no client.
    @Test func aStartInFlightWhenItsConnectionDropsIsAbortedNeverCommitted() throws {
        let a = Connection()
        var l = Lifecycle()
        let claim = l.claimStart(owner: ObjectIdentifier(a))
        let t = try #require(claim)
        let drop = l.requestStop("a", disconnectOf: ObjectIdentifier(a))
        #expect(drop == .abortStart)
        let committed = l.commitStart(t)
        #expect(!committed)
    }

    /// An explicit stop is the app's, from whichever connection it has now: never refused for ownership.
    @Test func anExplicitStopFromAnotherConnectionStillStops() throws {
        let a = Connection()
        var l = Lifecycle()
        let claim = l.claimStart(owner: ObjectIdentifier(a))
        let t = try #require(claim)
        _ = l.commitStart(t)
        let stop = l.requestStop("explicit")
        #expect(stop == .stop)
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
                      CaptureReplies.startTimedOut, CaptureReplies.cancelledWhileStarting, CaptureReplies.rotationTimedOut]
        #expect(Set(others + [CaptureReplies.noCaptureInProgress]).count == 7)
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
        #expect(outcome == StopSequence.Outcome(sealAbandoned: false, micAbandoned: false, tapAbandoned: false))
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

    /// Round 3 (E): a wedged audio queue (a disk stall) must not wedge Stop, or the start deadline's
    /// teardown, which frees the claim: the seal is bounded too, and the session still ends.
    @Test func aSealThatNeverReturnsStillEndsTheSession() {
        let log = Log()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let start = DispatchTime.now()
        let outcome = StopSequence.run(
            seal: { release.wait() },
            stopMic: { log.add("mic") }, stopTap: nil,
            timeout: 0.2, end: { log.add("end") })
        let waited = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        #expect(outcome.sealAbandoned)
        #expect(log.entries == ["mic", "end"], "the sources still stop, and the session still ends")
        #expect(waited < 1.5, "bounded")
    }

    /// Round 4 (N2): Stop reads its coverage INSIDE the bounded seal, on the audio queue, never with an
    /// unbounded `audioQueue.sync` of its own. A stalled audio queue: Stop still ends within the bound,
    /// and says the reading is missing (the caller falls back to the last cached one).
    @Test func aStalledAudioQueueNeverHoldsTheStopPastItsBound() {
        let audio = DispatchQueue(label: "stalled-audio")
        let release = DispatchSemaphore(value: 0)
        audio.async { release.wait() }   // a disk stall on the audio queue
        defer { release.signal() }
        let log = Log()
        let start = DispatchTime.now()
        let (outcome, read) = StopSequence.run(
            sealing: { audio.sync { 42 } }, stopMic: nil, stopTap: nil,
            timeout: 0.2, end: { read in log.add(read == nil ? "end without a reading" : "end") })
        let waited = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        #expect(outcome.sealAbandoned)
        #expect(read == nil)
        #expect(log.entries == ["end without a reading"])
        #expect(waited < 1.5)
    }

    @Test func aSealHandsBackWhatItReadOnTheAudioQueue() {
        let audio = DispatchQueue(label: "free-audio")
        let (outcome, read) = StopSequence.run(
            sealing: { audio.sync { 42 } }, stopMic: nil, stopTap: nil, timeout: 1, end: { _ in })
        #expect(!outcome.sealAbandoned)
        #expect(read == 42)
    }

    /// Round 5 item 4: `end` gets the seal's reading, so Stop records `.captureStop` BEFORE the session
    /// ends — while it is still the current one.
    @Test func endReceivesTheSealsReadingBeforeTheSessionEnds() {
        let log = Log()
        _ = StopSequence.run(sealing: { 42 }, stopMic: nil, stopTap: nil, timeout: 1,
                             end: { read in log.add("record \(read ?? -1)"); log.add("end session") })
        #expect(log.entries == ["record 42", "end session"])
    }

    @Test func aSealThatReturnsIsNotAbandoned() {
        let outcome = StopSequence.run(seal: {}, stopMic: nil, stopTap: nil, timeout: 1, end: {})
        #expect(!outcome.sealAbandoned)
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

/// Round 5 item 1: a rotation's writer swap on a stalled audio queue must not hold the XPC connection
/// (and a Stop queued behind it) past its bound. Abandoned means abandoned: the swap never applies late.
@Suite struct AbandonableStepTests {
    @Test func aStepOnAFreeQueueRunsAndReturns() {
        let queue = DispatchQueue(label: "free")
        let outcome = AbandonableStep.run(timeout: 1, on: queue) { 7 }
        #expect(outcome == .done(7))
    }

    @Test func aStepOnAStalledQueueIsAbandonedAndNeverRunsLate() {
        let queue = DispatchQueue(label: "stalled")
        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }
        let ran = OSAllocatedUnfairLock(initialState: false)
        let start = DispatchTime.now()
        let outcome = AbandonableStep.run(timeout: 0.2, on: queue) { ran.withLock { $0 = true }; return 7 }
        let waited = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        #expect(outcome == .abandoned)
        #expect(waited < 1.5)
        release.signal()
        queue.sync {}   // the queue drains: the abandoned step has had its chance to run
        #expect(!ran.withLock { $0 }, "no writer swap applies late")
    }

    /// Final review H3 #5: a step that STARTED but outlives both bounds is `.overran` — and it may still
    /// complete afterwards. That is why a rotation's swap re-checks its session before it installs the
    /// new chunk's paths (H-I2): the caller has long answered and moved on when it lands.
    @Test func aStepThatStartsButOutlivesItsBoundIsOverranAndStillCompletes() {
        let queue = DispatchQueue(label: "overrunning")
        let release = DispatchSemaphore(value: 0)
        let ran = OSAllocatedUnfairLock(initialState: false)
        let start = DispatchTime.now()
        let outcome = AbandonableStep.run(timeout: 0.2, on: queue) { () -> Int in
            release.wait()                  // a disk stall inside the swap
            ran.withLock { $0 = true }
            return 7
        }
        let waited = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        #expect(outcome == .overran)
        #expect(waited < 1.5)
        #expect(!ran.withLock { $0 }, "still running when the caller gave up on it")
        release.signal()
        queue.sync {}
        #expect(ran.withLock { $0 }, "it may still complete — late")
    }

    @Test func theRotationBoundIsThreeSeconds() {
        #expect(AbandonableStep.rotationTimeoutSeconds == 3)
    }
}

/// Round 5 item 3: the coverage cache belongs to one session; a refresh queued before a stall that
/// lands after the next start must not become that session's coverage.
@Suite struct SessionScopedCacheTests {
    @Test func aRefreshForAnotherSessionIsIgnored() {
        var cache = SessionScopedCache<Int>()
        cache.reset(session: 2)
        cache.update(session: 1, value: 10)     // the late refresh from session 1
        #expect(cache.value(for: 2) == nil)
        cache.update(session: 2, value: 20)
        #expect(cache.value(for: 2) == 20)
        #expect(cache.value(for: 1) == nil, "never handed to another session")
    }
}
