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

    @Test func recoverFromCrashAdvancesIndexAndKeepsOrphanAtCurrent() {
        let rotator = makeRotator()

        let plan = rotator.recoverFromCrash(now: Date(timeIntervalSince1970: 1000))

        #expect(plan.orphanIndex == 0)
        #expect(plan.orphanBaseName == "meeting-0")
        #expect(plan.recoveryIndex == 1)
        #expect(plan.recoveryBaseName == "meeting-1")
        #expect(rotator.currentBaseName == "meeting-1")
        #expect(rotator.currentChunkInfo.index == 1)
        #expect(rotator.currentChunkInfo.startTime == Date(timeIntervalSince1970: 1000))
    }

    @Test func secondRecoveryAdvancesFromTheNewIndex() {
        let rotator = makeRotator()
        _ = rotator.recoverFromCrash(now: Date(timeIntervalSince1970: 1000))

        let plan = rotator.recoverFromCrash(now: Date(timeIntervalSince1970: 2000))

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
        for _ in 0..<50 { await Task.yield() }
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
        for _ in 0..<50 { await Task.yield() }
        #expect(failures.value == 1 && rotator.currentChunkInfo.index == 0)
        #expect(rotated.value == 0, "a failed rotation is not a rotation")
    }
}
