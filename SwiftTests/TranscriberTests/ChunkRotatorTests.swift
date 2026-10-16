import Testing
import Foundation
import CoreFoundation
@testable import TranscriberCore

/// Fake XPC client. `ChunkRotator.rotate()` (the timer-driven path that calls this) is private
/// and scheduled off a `Timer`, so it isn't exercised here — these tests drive the deterministic,
/// synchronously-callable surface of the real class: base-name/index bookkeeping and crash
/// recovery, which is exactly the logic the old hand-copied `ChunkRotatorTests` characterized
/// without ever touching the real type.
private final class FakeChunkRotationClient: ChunkRotationClient {
    func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
        (systemPath: "\(outputDirectory)/\(newBaseName).wav", micPath: "\(outputDirectory)/\(newBaseName)_mic.wav")
    }
}

/// A mutable cell a test's closures can write to.
private final class Box<T> { var value: T; init(_ v: T) { value = v } }

private final class ThrowingRotationClient: ChunkRotationClient {
    struct Boom: Error {}
    func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) { throw Boom() }
}

@MainActor
struct ChunkRotatorTests {

    private func makeRotator(startTime: Date = Date(timeIntervalSince1970: 0)) -> ChunkRotator {
        ChunkRotator(
            captureClient: FakeChunkRotationClient(),
            outputDirectory: "/tmp/out",
            sessionBaseName: "meeting",
            chunkDurationMinutes: 10,
            startTime: startTime,
            onChunkFinalized: { _ in }
        )
    }

    @Test func currentBaseNameStartsAtChunkZero() {
        let rotator = makeRotator()
        #expect(rotator.currentBaseName == "meeting-0")
        #expect(rotator.currentChunkInfo.index == 0)
    }

    @Test func recoverFromCrashAdvancesIndexAndKeepsOrphanAtCurrent() async {
        let rotator = makeRotator()

        let plan = await rotator.recoverFromCrash(now: Date(timeIntervalSince1970: 1000))

        #expect(plan.orphanIndex == 0)
        #expect(plan.orphanBaseName == "meeting-0")
        #expect(plan.recoveryIndex == 1)
        #expect(plan.recoveryBaseName == "meeting-1")
        #expect(rotator.currentBaseName == "meeting-1")
        #expect(rotator.currentChunkInfo.index == 1)
        #expect(rotator.currentChunkInfo.startTime == Date(timeIntervalSince1970: 1000))
    }

    @Test func secondRecoveryAdvancesFromTheNewIndex() async {
        let rotator = makeRotator()
        _ = await rotator.recoverFromCrash(now: Date(timeIntervalSince1970: 1000))

        let plan = await rotator.recoverFromCrash(now: Date(timeIntervalSince1970: 2000))

        #expect(plan.orphanIndex == 1)
        #expect(plan.orphanBaseName == "meeting-1")
        #expect(plan.recoveryIndex == 2)
        #expect(rotator.currentBaseName == "meeting-2")
    }

    // MARK: - Run loop mode (#197)

    /// Waiting for a real firing isn't practical here — `chunkDurationMinutes` is whole minutes,
    /// far too long for a unit test — so this checks registration directly via CoreFoundation's
    /// toll-free bridge (`Timer` <-> `CFRunLoopTimer`) instead of observing a fire.
    @Test func startAddsTimerToMainRunLoopInCommonMode() {
        let rotator = makeRotator()
        rotator.start()
        defer { rotator.stop() }

        guard let timer = rotator.activeTimerForTesting else {
            Issue.record("expected an active timer after start()")
            return
        }
        let cfTimer = timer as CFRunLoopTimer
        #expect(CFRunLoopContainsTimer(CFRunLoopGetMain(), cfTimer, .commonModes))
        // And NOT solely relying on the default-mode registration `Timer.scheduledTimer` would have
        // given it — `.common` is a superset that still includes `.defaultRunLoopMode`.
        #expect(CFRunLoopContainsTimer(CFRunLoopGetMain(), cfTimer, .defaultMode))
    }

    // MARK: - Start index and on-disk names (R0/R2 review round 1, Critical)

    @Test func startIndexSetsTheFirstChunk() {
        let rotator = ChunkRotator(captureClient: FakeChunkRotationClient(), outputDirectory: "/tmp/out",
                                   sessionBaseName: "meeting", chunkDurationMinutes: 10, startIndex: 3,
                                   startTime: Date(timeIntervalSince1970: 0), onChunkFinalized: { _ in })
        #expect(rotator.currentBaseName == "meeting-3")
        #expect(rotator.currentChunkInfo.index == 3)
    }

    /// A rotation must never ask the helper for a file already on disk: `WavFileWriter` creates
    /// the file, so the helper would overwrite a chunk (the resumed recording's own file, or an
    /// unprocessed orphan) and that audio would be gone.
    @Test func rotationSkipsNamesAlreadyOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rotator-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("meeting-1.wav"))
        try Data().write(to: dir.appendingPathComponent("meeting-2_mic.wav"))
        try Data().write(to: dir.appendingPathComponent("meeting-3.m4a"))   // an archived chunk (round 3)

        final class Recorder: ChunkRotationClient {
            var requested: [String] = []
            func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
                requested.append(newBaseName)
                return ("\(outputDirectory)/\(newBaseName).wav", "\(outputDirectory)/\(newBaseName)_mic.wav")
            }
        }
        final class Sink { var finalized: [Int] = [] }
        let client = Recorder(), sink = Sink()
        let rotator = ChunkRotator(captureClient: client, outputDirectory: dir.path, sessionBaseName: "meeting",
                                   chunkDurationMinutes: 10, startTime: Date(timeIntervalSince1970: 0),
                                   onChunkFinalized: { sink.finalized.append($0.index) })
        await rotator.rotateForTesting()
        #expect(client.requested == ["meeting-4"])
        #expect(rotator.currentChunkInfo.index == 4)
        #expect(sink.finalized == [0])
    }

    // MARK: - onRotated (L7: every rotation refreshes the sentinel's liveness)

    @Test func onRotatedFiresAfterEverySuccessfulRotation() async throws {
        let fired = Box(0)
        let rotator = ChunkRotator(captureClient: FakeChunkRotationClient(), outputDirectory: "/tmp/out", sessionBaseName: "meeting",
                                   chunkDurationMinutes: 10, startTime: Date(timeIntervalSince1970: 0), onChunkFinalized: { _ in })
        rotator.onRotated = { fired.value += 1 }
        rotator.start()
        let timer = try #require(rotator.activeTimerForTesting)
        timer.fire()                                    // one rotation, synchronously scheduled
        await until { fired.value == 1 }
        for _ in 0..<50 { await Task.yield() }
        rotator.stop()
        #expect(fired.value == 1 && rotator.currentChunkInfo.index == 1)
    }

    // MARK: - Monotonic chunk clock (L11, §8.12)

    /// L15: chunk start times come from the monotonic clock anchored at the session start.
    @Test func chunkStartTimesComeFromTheMonotonicClock() async throws {
        let anchor = ContinuousClock.now
        let clock = MonotonicWallClock(anchorWall: Date(timeIntervalSince1970: 0), anchorMonotonic: anchor)
        let rotator = ChunkRotator(captureClient: FakeChunkRotationClient(), outputDirectory: "/tmp/out", sessionBaseName: "meeting",
                                   chunkDurationMinutes: 10, clock: clock, onChunkFinalized: { _ in })
        #expect(rotator.currentChunkInfo.startTime == Date(timeIntervalSince1970: 0))
        rotator.rotateNow()
        await until { rotator.currentChunkInfo.index == 1 }
        let t = rotator.currentChunkInfo.startTime.timeIntervalSince1970
        #expect(t >= 0 && t < 5, "derived from the monotonic clock, not from Date()")
    }

    // MARK: - Rotation failures (L8, §8.7)

    @Test func aThrowingRotateInvokesOnRotationFailedAndKeepsTheIndex() async throws {
        let failures = Box(0)
        let rotated = Box(0)
        let rotator = ChunkRotator(captureClient: ThrowingRotationClient(), outputDirectory: "/tmp/out", sessionBaseName: "meeting",
                                   chunkDurationMinutes: 10, startTime: Date(timeIntervalSince1970: 0), onChunkFinalized: { _ in })
        rotator.onRotationFailed = { _ in failures.value += 1 }
        rotator.onRotated = { rotated.value += 1 }
        rotator.rotateNow()
        await until { failures.value == 1 }   // the rotation looks at the folder off the main actor first (L review 158)
        #expect(failures.value == 1 && rotator.currentChunkInfo.index == 0)
        #expect(rotated.value == 0, "a failed rotation is not a rotation")
    }

    // MARK: - L review fixes

    /// A helper as it really behaves: `rotateChunk(newBaseName:)` seals the chunk it was writing, creates the
    /// new one ON DISK and answers with the SEALED chunk's paths. `lateOnce`: the first rotation completes in
    /// the helper, but its answer comes after the app's deadline (the app sees `CaptureCallTimeout`).
    private final class DiskHelper: ChunkRotationClient {
        let dir: URL
        var writing: String
        var lateOnce: Bool
        /// What the late attempt answers: the client's own timeout, or the helper's `rotationTimedOut` reply.
        var lateError: Error = CaptureCallTimeout(call: "rotateChunk", seconds: 10)
        var requested: [String] = []
        /// Held open by a test to overlap two rotations.
        var gate: (() async -> Void)?
        init(dir: URL, writing: String, lateOnce: Bool = false) { self.dir = dir; self.writing = writing; self.lateOnce = lateOnce }
        func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
            requested.append(newBaseName)
            await gate?()
            let sealed = writing
            writing = newBaseName
            for suffix in [".wav", "_mic.wav"] { try Data().write(to: dir.appendingPathComponent(newBaseName + suffix)) }
            if lateOnce { lateOnce = false; throw lateError }
            return (dir.appendingPathComponent(sealed + ".wav").path, dir.appendingPathComponent(sealed + "_mic.wav").path)
        }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rotator-late-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// L9 review 46: a rotation times out, and the helper completes it late — it is now writing chunk 1 while
    /// the app still names chunk 0. The next rotation reconciles first: chunk 0 is emitted from ITS OWN files,
    /// the helper's index adopted, and every chunk is processed exactly once, in order, from its own audio.
    @Test func aRotationCompletedLateIsReconciledAtTheNextRotation() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let helper = DiskHelper(dir: dir, writing: "meeting-0", lateOnce: true)
        let finalized = Box<[(index: Int, system: String)]>([])
        let rotator = ChunkRotator(captureClient: helper, outputDirectory: dir.path, sessionBaseName: "meeting",
                                   chunkDurationMinutes: 10, startTime: Date(timeIntervalSince1970: 0),
                                   onChunkFinalized: { finalized.value.append(($0.index, URL(fileURLWithPath: $0.systemPath).lastPathComponent)) })
        await rotator.rotateForTesting()   // times out; the helper completed it anyway
        #expect(finalized.value.isEmpty && rotator.currentChunkInfo.index == 0)
        await rotator.rotateForTesting()
        #expect(finalized.value.map(\.index) == [0, 1])
        #expect(finalized.value.map(\.system) == ["meeting-0.wav", "meeting-1.wav"], "each chunk from its own files")
        #expect(helper.requested == ["meeting-1", "meeting-2"])
        #expect(rotator.currentChunkInfo.index == 2 && rotator.currentBaseName == "meeting-2")
    }

    /// L review 91b: the helper's own "Rotation timed out" (its writer swap overran and may land late) is a
    /// refused rotation, not a dead capture — remembered like the client's timeout, and reconciled the same way.
    @Test func aRotationTheHelperSaysTimedOutIsReconciledLikeATimeout() async throws {
        struct HelperReply: Error, LocalizedError { var errorDescription: String? { CaptureReplies.rotationTimedOut } }
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let helper = DiskHelper(dir: dir, writing: "meeting-0", lateOnce: true)
        helper.lateError = HelperReply()
        let finalized = Box<[(index: Int, system: String)]>([])
        let rotator = ChunkRotator(captureClient: helper, outputDirectory: dir.path, sessionBaseName: "meeting",
                                   chunkDurationMinutes: 10, startTime: Date(timeIntervalSince1970: 0),
                                   onChunkFinalized: { finalized.value.append(($0.index, URL(fileURLWithPath: $0.systemPath).lastPathComponent)) })
        await rotator.rotateForTesting()   // "Rotation timed out" — and the swap landed late
        await rotator.rotateForTesting()
        #expect(finalized.value.map(\.index) == [0, 1])
        #expect(finalized.value.map(\.system) == ["meeting-0.wav", "meeting-1.wav"], "each chunk from its own files")
        #expect(rotator.currentBaseName == "meeting-2")
    }

    /// L9 review 46, at stop: the stop's own reconcile emits the chunk the late rotation sealed and adopts the
    /// helper's index, so the stop's last chunk is the one the helper was writing — never labelled as the old one.
    @Test func aRotationCompletedLateIsReconciledAtStop() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let helper = DiskHelper(dir: dir, writing: "meeting-0", lateOnce: true)
        let finalized = Box<[(index: Int, system: String)]>([])
        let rotator = ChunkRotator(captureClient: helper, outputDirectory: dir.path, sessionBaseName: "meeting",
                                   chunkDurationMinutes: 10, startTime: Date(timeIntervalSince1970: 0),
                                   onChunkFinalized: { finalized.value.append(($0.index, URL(fileURLWithPath: $0.systemPath).lastPathComponent)) })
        await rotator.rotateForTesting()
        #expect(await rotator.reconcileLateRotation())
        #expect(finalized.value.map(\.index) == [0] && finalized.value.first?.system == "meeting-0.wav")
        #expect(rotator.currentChunkInfo.index == 1, "the stop's last chunk is the helper's")
        #expect(!(await rotator.reconcileLateRotation()), "once")
    }

    /// … and a rotation that timed out WITHOUT completing changes nothing: the next one rotates the chunk the
    /// helper is really writing, past the timed-out attempt's name (which the helper may still create).
    @Test func aRotationThatNeverCompletedLeavesTheChunkWhereItWas() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        final class Flaky: ChunkRotationClient {
            var calls = 0
            var requested: [String] = []
            func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
                calls += 1
                requested.append(newBaseName)
                if calls == 1 { throw CaptureCallTimeout(call: "rotateChunk", seconds: 10) }
                return ("\(outputDirectory)/meeting-0.wav", "\(outputDirectory)/meeting-0_mic.wav")
            }
        }
        let client = Flaky()
        let finalized = Box<[Int]>([])
        let rotator = ChunkRotator(captureClient: client, outputDirectory: dir.path, sessionBaseName: "meeting",
                                   chunkDurationMinutes: 10, startTime: Date(timeIntervalSince1970: 0),
                                   onChunkFinalized: { finalized.value.append($0.index) })
        await rotator.rotateForTesting()
        #expect(!(await rotator.reconcileLateRotation()), "nothing on disk: not completed")
        await rotator.rotateForTesting()
        #expect(finalized.value == [0])
        #expect(client.requested == ["meeting-1", "meeting-2"], "never the timed-out attempt's name again")
        #expect(rotator.currentChunkInfo.index == 2)
    }

    /// L9 review 51: rotations chain — two overlapping `rotateNow()` name distinct chunks, in order.
    @Test func overlappingRotationsNameDistinctChunksInOrder() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let helper = DiskHelper(dir: dir, writing: "meeting-0")
        let released = Box(false)
        helper.gate = { while !released.value { await Task.yield() } }
        let finalized = Box<[Int]>([])
        let rotator = ChunkRotator(captureClient: helper, outputDirectory: dir.path, sessionBaseName: "meeting",
                                   chunkDurationMinutes: 10, startTime: Date(timeIntervalSince1970: 0),
                                   onChunkFinalized: { finalized.value.append($0.index) })
        rotator.rotateNow()
        rotator.rotateNow()
        await until { !helper.requested.isEmpty }
        for _ in 0..<20 { await Task.yield() }
        #expect(helper.requested == ["meeting-1"], "the second waits for the first")
        released.value = true
        await rotator.awaitRotationInFlight()
        #expect(helper.requested == ["meeting-1", "meeting-2"])
        #expect(finalized.value == [0, 1])
    }

    /// L11 review 68: a crash recovery's new chunk starts on the rotator's monotonic clock by default.
    @Test func recoverFromCrashDefaultsToTheMonotonicClock() async {
        let clock = MonotonicWallClock(anchorWall: Date(timeIntervalSince1970: 0), anchorMonotonic: ContinuousClock.now)
        let rotator = ChunkRotator(captureClient: FakeChunkRotationClient(), outputDirectory: "/tmp/out", sessionBaseName: "meeting",
                                   chunkDurationMinutes: 10, clock: clock, onChunkFinalized: { _ in })
        await rotator.recoverFromCrash()
        let t = rotator.currentChunkInfo.startTime.timeIntervalSince1970
        #expect(t >= 0 && t < 5, "from the monotonic clock, not Date()")
    }

    /// L10 review 54: a rotator that is gone takes its timer with it — no rotation timer left waking an idle
    /// app forever.
    @Test func aRotatorThatIsGoneInvalidatesItsTimer() async throws {
        var rotator: ChunkRotator? = makeRotator()
        rotator?.start()
        let timer = try #require(rotator?.activeTimerForTesting)
        #expect(timer.isValid, "live while its rotator is")
        rotator = nil
        #expect(!timer.isValid, "the rotator's deinit took it — before any fire (L review 118)")
        timer.fire()
        for _ in 0..<20 { await Task.yield() }
        #expect(!timer.isValid)
    }

    /// Pre-PR review: a second `start()` with no `stop()` between — the real wake arriving after the watchdog's implicit one
    /// (L review 104) — replaces the timer. The first used to stay on the run loop, so two timers rotated until Stop.
    @Test func aSecondStartLeavesOneTimerRotating() async throws {
        let fired = Box(0)
        let rotator = makeRotator()
        rotator.onRotated = { fired.value += 1 }
        rotator.start()
        let first = try #require(rotator.activeTimerForTesting)
        rotator.start()
        let second = try #require(rotator.activeTimerForTesting)
        defer { rotator.stop(); first.invalidate() }
        #expect(second !== first && second.isValid)
        #expect(!first.isValid, "the timer it replaced no longer fires")
        first.fire(); second.fire()                     // one chunk later: every timer still alive comes due
        await until { fired.value >= 1 }
        for _ in 0..<50 { await Task.yield() }
        await rotator.awaitRotationInFlight()
        #expect(fired.value == 1 && rotator.currentChunkInfo.index == 1, "one rotation per chunk, not two")
    }

    /// Polls `condition` (up to about 2 s): the rotation looks at its folder off the main actor (L review 158), so a
    /// fixed number of yields is not enough.
    private func until(_ condition: () -> Bool) async {
        var waited = 0
        while !condition(), waited < 400 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            waited += 1
        }
    }

    // MARK: - L round B (113, 115, 118)

    private func rotator(_ client: any ChunkRotationClient, dir: URL, startIndex: Int = 0, startTime: Date = Date(timeIntervalSince1970: 0),
                         finalized: Box<[(index: Int, system: String)]>, rotated: Box<Int>) -> ChunkRotator {
        let r = ChunkRotator(captureClient: client, outputDirectory: dir.path, sessionBaseName: "meeting",
                             chunkDurationMinutes: 10, startIndex: startIndex, startTime: startTime,
                             onChunkFinalized: { finalized.value.append(($0.index, URL(fileURLWithPath: $0.systemPath).lastPathComponent)) })
        r.onRotated = { rotated.value += 1 }
        return r
    }

    /// L review 113: the Stop's last chunk is the one the helper's stop reply NAMES — never one chunk's audio under
    /// another's index. A reply naming a later chunk than the rotator's current one (a rotation completed that no
    /// file check showed) emits the current chunk from its own files first.
    @Test func theStopsLastChunkIsTheOneItsReplyNames() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let finalized = Box<[(index: Int, system: String)]>([]), rotated = Box(0)
        let r = rotator(FakeChunkRotationClient(), dir: dir, finalized: finalized, rotated: rotated)
        let last = await r.lastChunkAtStop(systemPath: dir.appendingPathComponent("meeting-1.wav").path,
                                     micPath: dir.appendingPathComponent("meeting-1_mic.wav").path)
        #expect(last.index == 1 && URL(fileURLWithPath: last.systemPath).lastPathComponent == "meeting-1.wav")
        #expect(finalized.value.map(\.index) == [0] && finalized.value.first?.system == "meeting-0.wav", "chunk 0 from its own files")
        #expect(r.currentChunkInfo.index == 1)
        let same = rotator(FakeChunkRotationClient(), dir: dir, finalized: Box([]), rotated: rotated)
        #expect(await same.lastChunkAtStop(systemPath: dir.appendingPathComponent("meeting-0.wav").path,
                                           micPath: dir.appendingPathComponent("meeting-0_mic.wav").path).index == 0)
        #expect(rotated.value == 0, "settling at Stop is not a rotation (L review 118)")
    }

    /// L review 118: a reconcile at Stop or at a crash is not a rotation — `onRotated` (liveness, the disk check)
    /// fires only for a rotation.
    @Test func aReconcileAtACrashIsNotARotation() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let helper = DiskHelper(dir: dir, writing: "meeting-0", lateOnce: true)
        let finalized = Box<[(index: Int, system: String)]>([]), rotated = Box(0)
        let r = rotator(helper, dir: dir, finalized: finalized, rotated: rotated)
        await r.rotateForTesting()   // times out; completed late
        await r.recoverFromCrash()
        #expect(finalized.value.map(\.index) == [0], "reconciled")
        #expect(rotated.value == 0, "not announced as a rotation")
    }

    /// L review 115: a rotation still in flight when a crash recovery runs belongs to the dead helper: its late
    /// timeout is never remembered, so the recovery chunk the NEW helper writes is never taken for its completion.
    @Test func aStaleAttemptDoesNotSurviveACrashRecovery() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let helper = DiskHelper(dir: dir, writing: "meeting-2")
        let released = Box(false), gated = Box(true)
        helper.gate = { if gated.value { while !released.value { await Task.yield() } } }
        let finalized = Box<[(index: Int, system: String)]>([]), rotated = Box(0)
        let r = rotator(helper, dir: dir, startIndex: 2, finalized: finalized, rotated: rotated)
        helper.lateOnce = true
        r.rotateNow()   // asks for meeting-3; the helper dies before answering
        await until { !helper.requested.isEmpty }
        let plan = await r.recoverFromCrash()
        // Past every index ever asked for (L review 207): the dead helper may have created meeting-3 before it died.
        #expect(plan.recoveryIndex == 4)
        gated.value = false
        helper.writing = "meeting-4"   // the NEW helper records the recovery chunk
        released.value = true
        await r.awaitRotationInFlight()   // the dead helper's attempt times out now
        await r.rotateForTesting()
        #expect(finalized.value.map(\.index) == [4], "chunk 4 once, from the reply — never early, never twice")
        #expect(r.currentChunkInfo.index == 5)
    }

    /// L review 118: the reply names a late attempt's chunk (it completed between the check and the next rotate):
    /// the chunks are emitted in order, each from its own files, the late one from the reply.
    @Test func aReplyNamingALateChunkEmitsEachFromItsOwnFiles() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        final class LateBetween: ChunkRotationClient {
            let dir: URL
            var calls = 0
            init(dir: URL) { self.dir = dir }
            func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
                calls += 1
                if calls == 1 { throw CaptureCallTimeout(call: "rotateChunk", seconds: 10) }   // not created (yet)
                // The first attempt completes now, just before this one: the helper was writing meeting-1.
                for s in [".wav", "_mic.wav"] { try Data().write(to: dir.appendingPathComponent("meeting-1" + s)) }
                for s in [".wav", "_mic.wav"] { try Data().write(to: dir.appendingPathComponent(newBaseName + s)) }
                return (dir.appendingPathComponent("meeting-1.wav").path, dir.appendingPathComponent("meeting-1_mic.wav").path)
            }
        }
        let finalized = Box<[(index: Int, system: String)]>([]), rotated = Box(0)
        let r = rotator(LateBetween(dir: dir), dir: dir, finalized: finalized, rotated: rotated)
        await r.rotateForTesting()
        await r.rotateForTesting()
        #expect(finalized.value.map(\.index) == [0, 1])
        #expect(finalized.value.map(\.system) == ["meeting-0.wav", "meeting-1.wav"])
        #expect(r.currentChunkInfo.index == 2)
    }

    /// L review 118: two consecutive rotations time out, and both completed late: every chunk is emitted once, in
    /// order, from its own files.
    @Test func twoConsecutiveLateAttemptsAreEachEmittedOnce() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        final class TwiceLate: ChunkRotationClient {
            let dir: URL
            var calls = 0
            var writing = "meeting-0"
            init(dir: URL) { self.dir = dir }
            func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
                calls += 1
                let sealed = writing
                writing = newBaseName
                for s in [".wav", "_mic.wav"] { try Data().write(to: dir.appendingPathComponent(newBaseName + s)) }
                if calls <= 2 { throw CaptureCallTimeout(call: "rotateChunk", seconds: 10) }
                return (dir.appendingPathComponent(sealed + ".wav").path, dir.appendingPathComponent(sealed + "_mic.wav").path)
            }
        }
        let finalized = Box<[(index: Int, system: String)]>([]), rotated = Box(0)
        let r = rotator(TwiceLate(dir: dir), dir: dir, finalized: finalized, rotated: rotated)
        await r.rotateForTesting()   // meeting-1: timed out, completed
        await r.rotateForTesting()   // the reconcile adopts 1; meeting-2: timed out, completed
        await r.rotateForTesting()   // the reconcile adopts 2; meeting-3 answered
        #expect(finalized.value.map(\.index) == [0, 1, 2])
        #expect(finalized.value.map(\.system) == ["meeting-0.wav", "meeting-1.wav", "meeting-2.wav"])
        #expect(r.currentChunkInfo.index == 3)
    }

    // MARK: - L round C (158)

    /// L review 158: the rotation's look at the session folder runs off the main actor, bounded. A share that stops
    /// answering mid-recording never blocks it: the look is skipped, the next index comes from the counter, and the
    /// folder is said not to answer. A crash recovery on the same folder is never blocked either.
    @Test func aRotationWhoseFolderDoesNotAnswerIsNeverBlocked() async throws {
        let hung = HungStep("rotation: chunk files")
        defer { hung.release() }
        let finalized = Box<[(index: Int, system: String)]>([]), rotated = Box(0)
        let notAnswering = Box<[String]>([])
        let r = rotator(FakeChunkRotationClient(), dir: URL(fileURLWithPath: "/tmp/out"), finalized: finalized, rotated: rotated)
        r.folderReads = FolderReads(label: "rotator-hung-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
        r.folderProbeSeconds = 0.2
        r.onFolderNotAnswering = { notAnswering.value.append($0) }
        let began = ContinuousClock.now
        await r.rotateForTesting()
        #expect(ContinuousClock.now - began < .seconds(1), "bounded")
        #expect(hung.reached, "the look ran on the folder queue")
        #expect(r.currentChunkInfo.index == 1 && finalized.value.map(\.index) == [0], "rotated, by the counter")
        #expect(rotated.value == 1)
        #expect(!notAnswering.value.isEmpty, "said")
        let plan = await r.recoverFromCrash()
        #expect(plan.recoveryIndex == 2 && ContinuousClock.now - began < .seconds(2))
    }

    // MARK: - L round D (169, 172)

    /// A helper whose writer swap creates the next chunk's files and then overruns (H2's `.overran`): the app hears
    /// "Rotation timed out", the files stay on disk — and at the Stop the swap is abandoned, so the helper seals the
    /// chunk it was writing all along.
    private final class OverranHelper: ChunkRotationClient {
        struct TimedOut: Error, LocalizedError { var errorDescription: String? { CaptureReplies.rotationTimedOut } }
        let dir: URL
        /// Which rotations create their files before they overrun (by call, from 1); the others are abandoned unstarted.
        var createsFiles: (Int) -> Bool = { _ in true }
        var calls = 0
        init(dir: URL) { self.dir = dir }
        func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
            calls += 1
            if createsFiles(calls) {
                for s in [".wav", "_mic.wav"] { try Data().write(to: dir.appendingPathComponent(newBaseName + s)) }
            }
            throw TimedOut()
        }
    }

    /// L review 169: at Stop the helper's reply is read FIRST. It names the chunk the rotator names — the overrun swap
    /// to chunk 1 never took over, though its files are on disk — so the late attempt is dropped without a file check:
    /// chunk 0 is the Stop's last chunk, emitted exactly once, with its own start (never chunk 1's).
    @Test func aStopReplyNamingTheCurrentChunkIsTrustedOverTheLateAttemptsFiles() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let finalized = Box<[(index: Int, system: String)]>([]), rotated = Box(0)
        let r = rotator(OverranHelper(dir: dir), dir: dir, finalized: finalized, rotated: rotated)
        await r.rotateForTesting()   // "Rotation timed out": meeting-1's files are on disk, the helper still writes meeting-0
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting-1.wav").path))
        let last = await r.lastChunkAtStop(systemPath: dir.appendingPathComponent("meeting-0.wav").path,
                                           micPath: dir.appendingPathComponent("meeting-0_mic.wav").path)
        #expect(finalized.value.isEmpty, "chunk 0 is not emitted before the Stop hands it over: \(finalized.value)")
        #expect(last.index == 0 && URL(fileURLWithPath: last.systemPath).lastPathComponent == "meeting-0.wav")
        #expect(last.startTime == Date(timeIntervalSince1970: 0), "its own start, never chunk 1's file's")
        #expect(r.currentChunkInfo.index == 0)
    }

    /// … and a reply naming late attempt k emits the current chunk and the attempts below k that the helper opened, each
    /// from its own files, then hands back k. An attempt below k that never opened its file is not emitted.
    @Test func aStopReplyNamingALateAttemptEmitsTheChunksBeforeItFromTheirOwnFiles() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let helper = OverranHelper(dir: dir)
        helper.createsFiles = { $0 == 2 }   // the swap to meeting-1 was abandoned unstarted; the one to meeting-2 overran
        let finalized = Box<[(index: Int, system: String)]>([]), rotated = Box(0)
        let r = rotator(helper, dir: dir, finalized: finalized, rotated: rotated)
        await r.rotateForTesting()
        await r.rotateForTesting()
        #expect(finalized.value.isEmpty && r.currentChunkInfo.index == 0)
        let last = await r.lastChunkAtStop(systemPath: dir.appendingPathComponent("meeting-2.wav").path,
                                           micPath: dir.appendingPathComponent("meeting-2_mic.wav").path)
        #expect(finalized.value.map(\.index) == [0] && finalized.value.map(\.system) == ["meeting-0.wav"])
        #expect(last.index == 2 && URL(fileURLWithPath: last.systemPath).lastPathComponent == "meeting-2.wav")
        #expect(last.startTime > Date(timeIntervalSince1970: 0), "chunk 2 starts when its file was made")
        #expect(r.currentChunkInfo.index == 2)
    }

    /// … and only a name that is not this session's falls back to the file check (the late attempt's file says where
    /// the helper was).
    @Test func aStopReplyNotNamingThisSessionFallsBackToTheFileCheck() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let helper = DiskHelper(dir: dir, writing: "meeting-0", lateOnce: true)
        let finalized = Box<[(index: Int, system: String)]>([]), rotated = Box(0)
        let r = rotator(helper, dir: dir, finalized: finalized, rotated: rotated)
        await r.rotateForTesting()   // timed out; the helper completed it and writes meeting-1
        let last = await r.lastChunkAtStop(systemPath: dir.appendingPathComponent("other-5.wav").path,
                                           micPath: dir.appendingPathComponent("other-5_mic.wav").path)
        #expect(finalized.value.map(\.index) == [0], "reconciled from the files")
        #expect(last.index == 1 && r.currentChunkInfo.index == 1)
    }

    // MARK: - L round E (207, 208, 212, 213)

    private func hanging(_ hung: HungStep) -> FolderReads {
        FolderReads(label: "rotator-hung-\(UUID().uuidString)", beforeEachRead: { hung.hangIfNamed($0) })
    }

    /// L review 207, data loss: a crash recovery whose look does not answer names its chunk past EVERY index ever asked
    /// for — a late attempt the helper created (N+1 on disk), and one whose rotate failed with any other error — never the
    /// counter's `current + 1`, which the helper's `createFile` would truncate.
    @Test func aCrashRecoveryWhoseLookDoesNotAnswerNeverNamesAChunkAlreadyAskedFor() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let helper = DiskHelper(dir: dir, writing: "meeting-0", lateOnce: true)
        let finalized = Box<[(index: Int, system: String)]>([]), rotated = Box(0)
        let r = rotator(helper, dir: dir, finalized: finalized, rotated: rotated)
        await r.rotateForTesting()   // meeting-1: timed out, and the helper created it — with its pre-crash audio
        let audio = Data(repeating: 7, count: 4_096)
        try audio.write(to: dir.appendingPathComponent("meeting-1.wav"))
        let hung = HungStep("rotation: chunk files")
        defer { hung.release() }
        r.folderReads = hanging(hung)
        r.folderProbeSeconds = 0.2
        let plan = await r.recoverFromCrash()
        #expect(plan.recoveryIndex >= 2, "never meeting-1: \(plan.recoveryIndex)")
        #expect(try Data(contentsOf: dir.appendingPathComponent("meeting-1.wav")) == audio, "N+1's file is untouched")
        // L review 239: meeting-1 could not be checked — it is kept for the next look that answers, never dropped: the
        // restarted capture's first rotation emits it from its own files.
        hung.release()
        r.folderReads = FolderReads(label: "rotator-g-\(UUID().uuidString)")
        helper.writing = "meeting-\(plan.recoveryIndex)"
        await r.rotateForTesting()
        #expect(finalized.value.map(\.index).contains(1), "the late chunk is emitted: \(finalized.value)")
        #expect(finalized.value.first { $0.index == 1 }?.system == "meeting-1.wav", "from its own files")
        // … and a rotate that failed with any other error: its name was asked for too.
        let failing = ChunkRotator(captureClient: ThrowingRotationClient(), outputDirectory: dir.path, sessionBaseName: "other",
                                   chunkDurationMinutes: 10, startTime: Date(timeIntervalSince1970: 0), onChunkFinalized: { _ in })
        await failing.rotateForTesting()   // asked for other-1: failed
        failing.folderReads = hanging(hung)
        failing.folderProbeSeconds = 0.2
        #expect(await failing.recoverFromCrash().recoveryIndex >= 2)
    }

    /// L review 208: `stop()` is checked after each look — a rotation whose look was still out when the rotator stopped
    /// never sends its rotate.
    @Test func aStoppedRotatorNeverSendsTheRotateItWasLookingFor() async throws {
        final class Counting: ChunkRotationClient {
            var calls = 0
            func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
                calls += 1
                return (outputDirectory + "/" + newBaseName + ".wav", outputDirectory + "/" + newBaseName + "_mic.wav")
            }
        }
        let client = Counting()
        let hung = HungStep("rotation: chunk files")
        defer { hung.release() }
        let r = rotator(client, dir: URL(fileURLWithPath: "/tmp/out"), finalized: Box([]), rotated: Box(0))
        r.folderReads = hanging(hung)
        r.folderProbeSeconds = 0.2
        r.rotateNow()
        await until { hung.reached }
        r.stop()
        await r.awaitRotationInFlight()
        #expect(client.calls == 0, "a stopped rotator sends no rotate")
        #expect(r.currentChunkInfo.index == 0)
    }

    /// L review 212: a late-opened chunk whose file's creation cannot be read (the look did not answer) starts no earlier
    /// than when it was ASKED for — never at the chunk before it, which would overlap them.
    @Test func aLateChunkNeverStartsBeforeItWasAskedFor() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let helper = OverranHelper(dir: dir)
        helper.createsFiles = { $0 == 1 }
        let finalized = Box<[(index: Int, system: String)]>([]), rotated = Box(0)
        let r = rotator(helper, dir: dir, finalized: finalized, rotated: rotated)
        await r.rotateForTesting()   // meeting-1 asked for: overran, its files on disk
        let hung = HungStep("rotation: chunk files")
        defer { hung.release() }
        r.folderReads = hanging(hung)
        r.folderProbeSeconds = 0.2
        let last = await r.lastChunkAtStop(systemPath: dir.appendingPathComponent("meeting-1.wav").path,
                                           micPath: dir.appendingPathComponent("meeting-1_mic.wav").path)
        #expect(last.index == 1 && finalized.value.map(\.index) == [0])
        #expect(last.startTime > Date(timeIntervalSince1970: 0), "no earlier than it was asked for, never chunk 0's start")
    }

    /// L review 222 (169's third branch): the Stop's reply names an EARLIER chunk than the rotator's current one — an
    /// overrun swap left its files, a look adopted it, yet the helper sealed the chunk before. Its start is its own: when the
    /// look does not answer, when it was asked for (L review 212), never the current chunk's start.
    @Test func aStopNamingAnEarlierChunkStartsItWhenItWasAskedFor() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let helper = OverranHelper(dir: dir)
        helper.createsFiles = { $0 <= 2 }
        let finalized = Box<[(index: Int, system: String)]>([]), rotated = Box(0)
        // Anchored now, so its clock and the test's agree (to the scheduling slack below).
        let r = rotator(helper, dir: dir, startTime: Date(), finalized: finalized, rotated: rotated)
        let askedAt = Date().addingTimeInterval(-0.05)
        await r.rotateForTesting()   // meeting-1 asked for: overran, its files on disk
        let nextAskedAt = Date().addingTimeInterval(0.05)
        await r.rotateForTesting()   // the look adopts meeting-1; meeting-2 asked for: overran, its files on disk
        await r.rotateForTesting()   // the look adopts meeting-2; meeting-3 asked for: overran, nothing on disk
        let current = r.currentChunkInfo
        #expect(current.index == 2)
        let hung = HungStep("rotation: chunk files")
        defer { hung.release() }
        r.folderReads = hanging(hung)
        r.folderProbeSeconds = 0.2
        let last = await r.lastChunkAtStop(systemPath: dir.appendingPathComponent("meeting-1.wav").path,
                                           micPath: dir.appendingPathComponent("meeting-1_mic.wav").path)
        #expect(last.index == 1 && r.currentChunkInfo.index == 1)
        #expect(last.startTime < current.startTime, "its own start, never the current chunk's: \(last.startTime) vs \(current.startTime)")
        // Chunk 1's OWN start (L review 260): at or after it was asked for, and before chunk 2 was.
        #expect(last.startTime >= askedAt && last.startTime <= nextAskedAt, "\(last.startTime) not in [\(askedAt), \(nextAskedAt)]")
    }

    /// L review 213: late chunks between the current chunk and the one the Stop's reply names, which a look that did not
    /// answer could not check, are never dropped silently: said, by index.
    @Test func lateChunksTheStopCouldNotCheckAreSaid() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let helper = OverranHelper(dir: dir)
        helper.createsFiles = { $0 == 2 }   // the swap to meeting-1 made no file yet; the one to meeting-2 overran
        let finalized = Box<[(index: Int, system: String)]>([]), rotated = Box(0)
        let unchecked = Box<[Int]>([])
        let r = rotator(helper, dir: dir, finalized: finalized, rotated: rotated)
        r.onLateChunksUnchecked = { unchecked.value += $0 }
        await r.rotateForTesting()   // meeting-1: timed out
        await r.rotateForTesting()   // meeting-2: overran
        let hung = HungStep("rotation: chunk files")
        defer { hung.release() }
        r.folderReads = hanging(hung)
        r.folderProbeSeconds = 0.2
        let last = await r.lastChunkAtStop(systemPath: dir.appendingPathComponent("meeting-2.wav").path,
                                           micPath: dir.appendingPathComponent("meeting-2_mic.wav").path)
        #expect(last.index == 2)
        #expect(unchecked.value == [1], "chunk 1 could not be checked: said, never silently dropped")
    }

    /// … and one a rotation's late reply could not check is settled at the next look that answers: emitted from its own
    /// files, since the helper opened it.
    @Test func aLateChunkARotationCouldNotCheckIsEmittedOnceTheFolderAnswers() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        final class TwoLandLate: ChunkRotationClient {
            let dir: URL
            var calls = 0
            var writing = "meeting-0"
            init(dir: URL) { self.dir = dir }
            func create(_ base: String) throws { for s in [".wav", "_mic.wav"] { try Data().write(to: dir.appendingPathComponent(base + s)) } }
            func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
                calls += 1
                if calls <= 2 { throw CaptureCallTimeout(call: "rotateChunk", seconds: 10) }   // meeting-1, meeting-2: not yet
                if calls == 3 {   // both late swaps land just before this one: the helper was writing meeting-2
                    try create("meeting-1"); try create("meeting-2")
                    writing = "meeting-2"
                }
                let sealed = writing
                writing = newBaseName
                try create(newBaseName)
                return (dir.appendingPathComponent(sealed + ".wav").path, dir.appendingPathComponent(sealed + "_mic.wav").path)
            }
        }
        let finalized = Box<[(index: Int, system: String)]>([]), rotated = Box(0)
        let r = rotator(TwoLandLate(dir: dir), dir: dir, finalized: finalized, rotated: rotated)
        await r.rotateForTesting()   // meeting-1: timed out
        await r.rotateForTesting()   // meeting-2: timed out
        // The next rotation's look answers; its late reply's look — for the chunks before the one it names — does not.
        let looks = Box(0)
        let hung = HungStep("rotation: chunk files")
        defer { hung.release() }
        r.folderReads = FolderReads(label: "rotator-hung-\(UUID().uuidString)", beforeEachRead: { name in
            looks.value += 1
            if looks.value == 2 { hung.hangIfNamed(name) }
        })
        r.folderProbeSeconds = 0.2
        await r.rotateForTesting()
        #expect(finalized.value.map(\.index) == [0, 2], "chunk 1 could not be checked yet: \(finalized.value.map(\.index))")
        hung.release()
        _ = await r.folderReads.read("settle", folder: dir.path, seconds: 5) { 0 }   // the hung look has finished on its queue
        await r.rotateForTesting()   // a look that answers
        #expect(finalized.value.map(\.index).sorted() == [0, 1, 2, 3], "chunk 1 from its own files once the folder answered: \(finalized.value.map(\.index))")
        #expect(finalized.value.first { $0.index == 1 }?.system == "meeting-1.wav")
    }

    /// L review 172: a reconcile is a rotation only when the rotation itself says so — `announce` defaults to false.
    @Test func aReconcileAnnouncesNothingByDefault() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let helper = DiskHelper(dir: dir, writing: "meeting-0", lateOnce: true)
        let finalized = Box<[(index: Int, system: String)]>([]), rotated = Box(0)
        let r = rotator(helper, dir: dir, finalized: finalized, rotated: rotated)
        await r.rotateForTesting()
        #expect(await r.reconcileLateRotation())
        #expect(rotated.value == 0, "not a rotation")
    }

    // MARK: - L round G (239, 241)

    /// A client that fails its first `failures` rotates with a non-timeout error, then answers as the helper does — creating
    /// the file it is given — and records every name asked for.
    private final class FailsThenAnswers: ChunkRotationClient {
        let dir: URL
        var failures: Int
        var requested: [String] = []
        var writing = "meeting-0"
        init(dir: URL, failures: Int) { self.dir = dir; self.failures = failures }
        func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
            requested.append(newBaseName)
            if failures > 0 { failures -= 1; throw ThrowingRotationClient.Boom() }
            let sealed = writing
            writing = newBaseName
            for suffix in [".wav", "_mic.wav"] { try Data().write(to: dir.appendingPathComponent(newBaseName + suffix)) }
            return (dir.appendingPathComponent(sealed + ".wav").path, dir.appendingPathComponent(sealed + "_mic.wav").path)
        }
    }

    /// L review 241: a look that answers probes the next free name from the shared counter — past every name ever asked
    /// for — never from below it, where a chunk file already on disk beyond it would be missed and truncated.
    @Test func anAnsweredLookProbesFromTheCounter() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let client = FailsThenAnswers(dir: dir, failures: 1)
        let r = rotator(client, dir: dir, finalized: Box([]), rotated: Box(0))
        await r.rotateForTesting()   // meeting-1 asked for: failed (not a timeout)
        let kept = Data(repeating: 9, count: 1_024)
        try kept.write(to: dir.appendingPathComponent("meeting-2.wav"))   // a chunk file already there
        await r.rotateForTesting()
        #expect(client.requested == ["meeting-1", "meeting-3"], "\(client.requested)")
        #expect(try Data(contentsOf: dir.appendingPathComponent("meeting-2.wav")) == kept, "never truncated")
    }

    /// L review 241 (pinned, 207): a rotation after a non-timeout failure, whose look does not answer, still names a chunk past
    /// the one the failed rotate asked for.
    @Test func aRotationPastAFailureWithAHungLookNamesPastIt() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let client = FailsThenAnswers(dir: dir, failures: 1)
        let r = rotator(client, dir: dir, finalized: Box([]), rotated: Box(0))
        await r.rotateForTesting()   // meeting-1: failed
        let hung = HungStep("rotation: chunk files")
        defer { hung.release() }
        r.folderReads = hanging(hung)
        r.folderProbeSeconds = 0.2
        await r.rotateForTesting()
        #expect(client.requested == ["meeting-1", "meeting-2"], "\(client.requested)")
    }

    /// L reviews 212, 241: a late chunk no look could check, emitted once a look answers, starts no earlier than it was ASKED
    /// for — its asked-at kept while it waits — even when its file says it was created before that.
    @Test func anUncheckedLateChunkStartsNoEarlierThanItWasAskedFor() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        final class TwoLandLate: ChunkRotationClient {
            let dir: URL
            var calls = 0
            var writing = "meeting-0"
            init(dir: URL) { self.dir = dir }
            func create(_ base: String) throws { for s in [".wav", "_mic.wav"] { try Data().write(to: dir.appendingPathComponent(base + s)) } }
            func rotateChunk(outputDirectory: String, newBaseName: String) async throws -> (systemPath: String, micPath: String) {
                calls += 1
                if calls <= 2 { throw CaptureCallTimeout(call: "rotateChunk", seconds: 10) }
                if calls == 3 { try create("meeting-1"); try create("meeting-2"); writing = "meeting-2" }
                let sealed = writing
                writing = newBaseName
                try create(newBaseName)
                return (dir.appendingPathComponent(sealed + ".wav").path, dir.appendingPathComponent(sealed + "_mic.wav").path)
            }
        }
        let starts = Box<[Int: Date]>([:])
        let began = Date(timeIntervalSince1970: 1_000)
        let r = ChunkRotator(captureClient: TwoLandLate(dir: dir), outputDirectory: dir.path, sessionBaseName: "meeting",
                             chunkDurationMinutes: 10, startTime: began, onChunkFinalized: { starts.value[$0.index] = $0.startTime })
        await r.rotateForTesting()   // meeting-1: timed out
        await r.rotateForTesting()   // meeting-2: timed out
        let looks = Box(0)
        let hung = HungStep("rotation: chunk files")
        defer { hung.release() }
        r.folderReads = FolderReads(label: "rotator-hung-\(UUID().uuidString)", beforeEachRead: { name in
            looks.value += 1
            if looks.value == 2 { hung.hangIfNamed(name) }
        })
        r.folderProbeSeconds = 0.2
        await r.rotateForTesting()   // names meeting-2; the look for meeting-1 does not answer
        hung.release()
        _ = await r.folderReads.read("settle", folder: dir.path, seconds: 5) { 0 }
        // Its file says it was created before the rotator even began — before it was asked for.
        try FileManager.default.setAttributes([.creationDate: began.addingTimeInterval(-100)],
                                              ofItemAtPath: dir.appendingPathComponent("meeting-1.wav").path)
        await r.rotateForTesting()
        let start = try #require(starts.value[1], "chunk 1 emitted")
        #expect(start >= began, "never before it was asked for: \(start)")
    }
}
