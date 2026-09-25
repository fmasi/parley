import Foundation
import Testing
@testable import TranscriberCore

// Stream L, round G (items 235–250). The fake client and the harness are RecordingCoordinatorTests.swift's; `HungRead` is
// RecordingCoordinatorRoundCTests.swift's; `roundFPendingSession` and `roundFTearDown` are RecordingCoordinatorRoundFTests.swift's.

/// A pending session `name` whose transcript was already written (its finalized marker there): a retry's gate only cleans
/// it up.
@MainActor
func roundGFinishedPendingSession(_ h: Harness, _ name: String) async throws -> RecordingSentinel {
    let p = try roundFPendingSession(h, name)
    let dir = URL(fileURLWithPath: p.systemAudioPath).deletingLastPathComponent()
    _ = try #require(try await ChunkedSessionRecovery.recover(outputDirectory: dir, sessionId: name, config: h.config.config,
                                                               transcriber: FakeEngine(), diarizer: FakeDiarizer(), runner: h.runner))
    return p
}

// MARK: - Crash detection is disarmed only by whoever still owns the app (242)

@MainActor
@Suite struct CaptureOwnershipRoundGTests {
    /// L review 242 (129): the finalized gate awaits the adopt and the record's build between its ownership check and the end
    /// of the capture. A Start that gets in there owns the app: its crash detection is never disarmed — the gate's
    /// bookkeeping (the commit, the forget) still happens.
    @Test func aStartDuringAFinishedRetrysBuildKeepsItsCrashDetectionArmed() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { roundFTearDown(h) }
        let p = try await roundGFinishedPendingSession(h, "p")
        try RecordingSentinel.writePending([p], directory: h.tmp)
        let coordinator = h.coordinator, client = h.client
        client.onFinalizeDiagnostics = {
            client.onFinalizeDiagnostics = nil
            await coordinator.startRecording(sessionName: "new", microphoneDeviceId: nil)
        }
        await h.coordinator.retryPendingSessions()
        #expect(h.appState.isRecording && client.startCalls.count == 1, "the new recording runs")
        #expect(client.captureEndedCalls == 0, "its crash detection stays armed")
        #expect(RecordingSentinel.readPending(directory: h.tmp).isEmpty, "the finished session is still forgotten")
        #expect(client.commitCalls == ["p"], "and its evidence committed")
    }
}

// MARK: - A stuck recovery file never holds an exit, nor lets a stopped recording resume (235, 236)

/// A recovery-file queue that sticks at every operation named in `labels` (all of them when nil) while `stuck` is set — up
/// to its watchdog — as a folder that stopped answering does.
final class StuckSentinelQueue: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var isStuck = true
    }
    private let state = State()
    let io: SentinelIO
    init(_ labels: Set<String>? = nil, watchdog: Double = 10) {
        let state = state
        io = SentinelIO(label: "rc-g-sentinel-\(UUID().uuidString)", beforeEach: { label in
            guard labels?.contains(label) ?? true, state.lock.withLock({ state.isStuck }) else { return }
            _ = state.gate.wait(timeout: .now() + watchdog)
        })
    }
    /// Unsticks it: every waiting operation runs, and none waits again.
    func release() {
        state.lock.withLock { state.isStuck = false }
        for _ in 0..<50 { state.gate.signal() }
    }
}

@MainActor
@Suite struct StuckRecoveryFileRoundGTests {
    /// L review 235: the marks a logout makes — `willPowerOff`'s, the terminate delegate's, the preparation's — are bounded:
    /// a recovery file's queue stuck behind a hung operation never holds the reply past the termination's bound. The
    /// helper is still stopped.
    @Test func aStuckRecoveryFileNeverHoldsALogoutPastItsBound() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { roundFTearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        let stuck = StuckSentinelQueue()
        defer { stuck.release() }
        h.coordinator.sentinelIO = stuck.io
        let began = ContinuousClock.now
        h.coordinator.markPowerOffDuringFinalize()   // willPowerOff
        h.coordinator.markForTermination()           // the terminate delegate, before it answers
        await h.coordinator.prepareForTermination(bound: .seconds(2))
        let took = ContinuousClock.now - began
        #expect(took < .seconds(4), "replied within its bound: \(took)")
        #expect(h.client.stopCalls == 1, "the helper was still stopped")
    }

    /// L review 236: the Stop's stopping mark does not answer (the recovery file's queue is stuck), and Parley dies before the
    /// Stop is done. The next launch never RESUMES the recording the user stopped: it is salvaged.
    @Test func aStopWhoseMarkTimedOutIsNeverResumedAfterACrash() async throws {
        let h = try Harness()
        h.config.update { $0.recordingDirectory = h.tmp.appendingPathComponent("rec").path }
        defer { roundFTearDown(h) }
        await h.coordinator.startRecording(sessionName: "a", microphoneDeviceId: nil)
        #expect(RecordingSentinel.read(directory: h.tmp)?.stopping == false)
        let stuck = StuckSentinelQueue(["mark stopping"])
        h.coordinator.sentinelIO = stuck.io
        h.coordinator.sentinelDeadline = .milliseconds(200)
        // Parley "dies" inside the helper's stop: nothing after it runs until the test is over.
        let client = h.client
        let dead = Harness.Box<CheckedContinuation<Void, Never>?>(nil)
        client.onStop = { await withCheckedContinuation { dead.value = $0 } }
        let coordinator = h.coordinator
        let stopping = Task { await coordinator.stopRecording() }
        await Harness.until { dead.value != nil }
        #expect(dead.value != nil, "the Stop went on past its mark")
        #expect(RecordingSentinel.read(directory: h.tmp)?.stopping == false, "the mark never landed")
        // The relaunch: a new process, the same folders — the helper is not capturing, and the recording was alive a moment ago.
        let relaunched = try Harness(tmp: h.tmp)
        await relaunched.coordinator.recoverAtLaunch()
        #expect(relaunched.client.startCalls.isEmpty, "never resumed")
        #expect(relaunched.appState.isIdle && RecordingSentinel.read(directory: h.tmp) == nil, "salvaged")
        #expect(relaunched.appState.activeAlarms[.recordingResumedWithGap] == nil)
        // The first process is let go, its Stop finished, before the folder goes.
        stuck.release()
        client.onStop = nil
        dead.value?.resume()
        await stopping.value
    }
}

@Suite struct StopKeptApartDecisionRoundGTests {
    /// L review 236 (b): a Stop kept apart — asked for no earlier than the recording was last alive — is a stopping recording:
    /// salvaged, never resumed, and never re-attached (the helper that still captures is stopped by the relaunch).
    @Test func aStopKeptApartIsStopping() {
        let alive = Date(timeIntervalSince1970: 1000), now = alive.addingTimeInterval(20)
        func decide(_ requested: Date?, capturing: Bool = false) -> RelaunchDecision {
            RelaunchDecision.decide(lastAliveAt: alive, bootSessionUUID: "b", wasStopping: false, now: now, helperCapturing: capturing,
                                    currentBootSessionUUID: "b", folderReachable: true, stopRequestedAt: requested)
        }
        #expect(decide(nil) == .resumeSameSession(gapStart: alive))
        #expect(decide(alive.addingTimeInterval(5)) == .salvageAndStop(reason: .wasStopping))
        #expect(decide(alive.addingTimeInterval(5), capturing: true) == .salvageAndStop(reason: .wasStopping))
        #expect(decide(alive.addingTimeInterval(-5)) == .resumeSameSession(gapStart: alive), "alive after it: not this stop's")
    }
}

// MARK: - The exit's flush: a spent budget is not a hung folder (244)

@MainActor
@Suite struct ExitFlushRoundGTests {
    /// L review 244 (195): a flush that had no real budget left — the exit's deadline all but spent — says nothing about the
    /// folder: the app's own last flush is not skipped for it.
    @Test func aFlushWithNoBudgetLeftIsNotAHungFolder() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        h.client.onFlush = { try? await Task.sleep(for: .seconds(1)) }
        await h.coordinator.flushEvidenceForExit(by: SuspendingClock.now + .milliseconds(20))
        #expect(!h.coordinator.exitFlushTimedOut)
        h.coordinator.evidenceFlushBound = .milliseconds(200)
        await h.coordinator.flushEvidenceForExit(by: SuspendingClock.now + .seconds(2))
        #expect(h.coordinator.exitFlushTimedOut, "a real budget that ran out: the folder is not answering")
    }

    /// … and each exit attempt says it afresh: an earlier attempt's timeout never skips a later exit's last flush.
    @Test func eachExitAttemptSaysItsOwnFlush() async throws {
        let h = try Harness()
        defer { roundFTearDown(h) }
        h.client.onFlush = { try? await Task.sleep(for: .seconds(1)) }
        h.coordinator.evidenceFlushBound = .milliseconds(200)
        await h.coordinator.flushEvidenceForExit(by: SuspendingClock.now + .seconds(2))
        #expect(h.coordinator.exitFlushTimedOut)
        h.client.onFlush = nil
        await h.coordinator.prepareForTermination(bound: .seconds(2))   // nothing in flight: a quick exit
        #expect(!h.coordinator.exitFlushTimedOut)
        h.client.onFlush = { try? await Task.sleep(for: .seconds(1)) }
        await h.coordinator.flushEvidenceForExit(by: SuspendingClock.now + .seconds(2))
        h.client.onFlush = nil
        #expect(await h.coordinator.prepareForQuit(confirm: { true }))
        #expect(!h.coordinator.exitFlushTimedOut, "the Quit's own attempt")
    }
}
