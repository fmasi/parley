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
}
