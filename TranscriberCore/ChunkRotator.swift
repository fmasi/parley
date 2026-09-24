import Foundation
import os

@MainActor
public final class ChunkRotator {
    public struct FinalizedChunk {
        public let index: Int
        public let systemPath: String
        public let micPath: String
        public let startTime: Date

        public init(index: Int, systemPath: String, micPath: String, startTime: Date) {
            self.index = index
            self.systemPath = systemPath
            self.micPath = micPath
            self.startTime = startTime
        }
    }

    private let captureClient: any ChunkRotationClient
    private let outputDirectory: String
    private let sessionBaseName: String
    private let chunkDuration: TimeInterval
    private var timer: Timer?
    private var currentChunkIndex: Int
    private var currentChunkStartTime: Date
    private let onChunkFinalized: @MainActor (FinalizedChunk) -> Void

    /// - Parameter startIndex: the index of the chunk being recorded now. A resumed session starts
    ///   past its settled chunks; restarting at 0 made the last chunk collide with the seeded
    ///   chunk 0, and every word after the resume was dropped as a "duplicate".
    public init(
        captureClient: any ChunkRotationClient,
        outputDirectory: String,
        sessionBaseName: String,
        chunkDurationMinutes: Int,
        startIndex: Int = 0,
        startTime: Date,
        onChunkFinalized: @MainActor @escaping (FinalizedChunk) -> Void
    ) {
        self.captureClient = captureClient
        self.outputDirectory = outputDirectory
        self.sessionBaseName = sessionBaseName
        self.chunkDuration = TimeInterval(chunkDurationMinutes * 60)
        self.currentChunkIndex = startIndex
        self.currentChunkStartTime = startTime
        self.onChunkFinalized = onChunkFinalized
    }

    /// Test seam (`@testable import`): the active rotation timer, so tests can confirm it was
    /// added to the run loop in `.common` mode (#197) without waiting on a real firing.
    var activeTimerForTesting: Timer? { timer }

    /// The base name for the current chunk's WAV files.
    public var currentBaseName: String { "\(sessionBaseName)-\(currentChunkIndex)" }

    /// Info about the current (in-progress) chunk for final processing.
    public var currentChunkInfo: (index: Int, startTime: Date) {
        (index: currentChunkIndex, startTime: currentChunkStartTime)
    }

    /// Recover from a live XPC crash: advance to the next chunk index so the post-crash recording
    /// continues at a fresh chunk, and return the plan whose names the caller uses for the orphan
    /// (the current index) and the recovery segment. The caller MUST enqueue the orphan chunk
    /// (using `currentBaseName` / `currentChunkInfo`) BEFORE calling this — once it returns, the
    /// index has advanced (#92).
    @discardableResult
    public func recoverFromCrash(now: Date = Date()) -> ChunkRecoveryPlan {
        let planned = chunkRecoveryPlan(sessionBaseName: sessionBaseName, currentChunkIndex: currentChunkIndex)
        // The recovery segment's name must not be a file already on disk (same rule as rotate()).
        let recoveryIndex = nextFreeIndex(after: currentChunkIndex)
        let plan = recoveryIndex == planned.recoveryIndex ? planned : ChunkRecoveryPlan(
            orphanIndex: planned.orphanIndex, recoveryIndex: recoveryIndex,
            orphanBaseName: planned.orphanBaseName, recoveryBaseName: "\(sessionBaseName)-\(recoveryIndex)")
        currentChunkIndex = plan.recoveryIndex
        currentChunkStartTime = now
        Logger.audio.info("ChunkRotator recovered: orphan chunk \(plan.orphanIndex, privacy: .public), resuming at \(plan.recoveryIndex, privacy: .public)")
        return plan
    }

    /// Start the rotation timer.
    public func start() {
        Logger.audio.info("ChunkRotator started — interval: \(self.chunkDuration, privacy: .public)s, base: \(self.sessionBaseName, privacy: .sensitive)")
        let newTimer = Timer(timeInterval: chunkDuration, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.rotate()
            }
        }
        // `.common`, not `Timer.scheduledTimer`'s `.default`-only mode (#197): a modal panel
        // (NSOpenPanel, NSAlert) or an open menu's tracking run loop would otherwise pause
        // rotation entirely — meanwhile the chunk keeps growing and processing is delayed.
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    /// Stop the timer. Does NOT finalize the current chunk.
    public func stop() {
        timer?.invalidate()
        timer = nil
        Logger.audio.info("ChunkRotator stopped at chunk \(self.currentChunkIndex, privacy: .public)")
    }

    private func rotate() {
        Task { await performRotation() }
    }

    /// Test seam: one rotation, awaited.
    func rotateForTesting() async {
        await performRotation()
    }

    private func performRotation() async {
        let oldIndex = currentChunkIndex
        let oldStartTime = currentChunkStartTime
        let nextIndex = nextFreeIndex(after: oldIndex)
        let nextBaseName = "\(sessionBaseName)-\(nextIndex)"

        Logger.audio.info("Rotating chunk \(oldIndex, privacy: .public) → \(nextIndex, privacy: .public)")

        do {
            let paths = try await captureClient.rotateChunk(
                outputDirectory: outputDirectory,
                newBaseName: nextBaseName
            )
            self.currentChunkIndex = nextIndex
            self.currentChunkStartTime = Date()
            let finalized = FinalizedChunk(
                index: oldIndex,
                systemPath: paths.systemPath,
                micPath: paths.micPath,
                startTime: oldStartTime
            )
            self.onChunkFinalized(finalized)
        } catch {
            Logger.audio.error("ChunkRotator: failed to rotate chunk \(oldIndex, privacy: .public) → \(nextIndex, privacy: .public): \(error, privacy: .private)")
        }
    }

    /// The first index after `index` whose chunk files are not already on disk. The helper CREATES
    /// the file it is given, so reusing a name overwrites that chunk's audio — the file a resumed
    /// session is still writing, or an orphan that was never processed.
    private func nextFreeIndex(after index: Int) -> Int {
        var candidate = index + 1
        while chunkFilesExist(index: candidate) {
            Logger.audio.error("ChunkRotator: chunk \(candidate, privacy: .public) is already on disk — skipping to the next free name")
            candidate += 1
        }
        return candidate
    }

    private func chunkFilesExist(index: Int) -> Bool {
        // Every artefact a chunk leaves: its two WAVs and, once processed, its archive.
        let base = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(sessionBaseName)-\(index)")
        return [".wav", "_mic.wav", ".m4a"].contains { FileManager.default.fileExists(atPath: base.path + $0) }
    }
}
