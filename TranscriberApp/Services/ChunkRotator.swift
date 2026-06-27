import Foundation
import os
import TranscriberCore

@MainActor
final class ChunkRotator {
    struct FinalizedChunk {
        let index: Int
        let systemPath: String
        let micPath: String
        let startTime: Date
    }

    private let captureClient: AudioCaptureClient
    private let outputDirectory: String
    private let sessionBaseName: String
    private let chunkDuration: TimeInterval
    private var timer: Timer?
    private var currentChunkIndex: Int = 0
    private var currentChunkStartTime: Date
    private let onChunkFinalized: @MainActor (FinalizedChunk) -> Void

    init(
        captureClient: AudioCaptureClient,
        outputDirectory: String,
        sessionBaseName: String,
        chunkDurationMinutes: Int,
        startTime: Date,
        onChunkFinalized: @MainActor @escaping (FinalizedChunk) -> Void
    ) {
        self.captureClient = captureClient
        self.outputDirectory = outputDirectory
        self.sessionBaseName = sessionBaseName
        self.chunkDuration = TimeInterval(chunkDurationMinutes * 60)
        self.currentChunkStartTime = startTime
        self.onChunkFinalized = onChunkFinalized
    }

    /// The base name for the current chunk's WAV files.
    var currentBaseName: String { "\(sessionBaseName)-\(currentChunkIndex)" }

    /// Info about the current (in-progress) chunk for final processing.
    var currentChunkInfo: (index: Int, startTime: Date) {
        (index: currentChunkIndex, startTime: currentChunkStartTime)
    }

    /// Recover from a live XPC crash: advance to the next chunk index so the post-crash recording
    /// continues at a fresh chunk, and return the plan whose names the caller uses for the orphan
    /// (the current index) and the recovery segment. The caller MUST enqueue the orphan chunk
    /// (using `currentBaseName` / `currentChunkInfo`) BEFORE calling this — once it returns, the
    /// index has advanced (#92).
    @discardableResult
    func recoverFromCrash(now: Date = Date()) -> ChunkRecoveryPlan {
        let plan = chunkRecoveryPlan(sessionBaseName: sessionBaseName, currentChunkIndex: currentChunkIndex)
        currentChunkIndex = plan.recoveryIndex
        currentChunkStartTime = now
        Logger.audio.info("ChunkRotator recovered: orphan chunk \(plan.orphanIndex, privacy: .public), resuming at \(plan.recoveryIndex, privacy: .public)")
        return plan
    }

    /// Start the rotation timer.
    func start() {
        Logger.audio.info("ChunkRotator started — interval: \(self.chunkDuration, privacy: .public)s, base: \(self.sessionBaseName, privacy: .public)")
        timer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.rotate()
            }
        }
    }

    /// Stop the timer. Does NOT finalize the current chunk.
    func stop() {
        timer?.invalidate()
        timer = nil
        Logger.audio.info("ChunkRotator stopped at chunk \(self.currentChunkIndex, privacy: .public)")
    }

    private func rotate() {
        let oldIndex = currentChunkIndex
        let oldStartTime = currentChunkStartTime
        let nextIndex = oldIndex + 1
        let nextBaseName = "\(sessionBaseName)-\(nextIndex)"

        Logger.audio.info("Rotating chunk \(oldIndex, privacy: .public) → \(nextIndex, privacy: .public)")

        Task {
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
                Logger.audio.error("ChunkRotator: failed to rotate chunk \(oldIndex, privacy: .public) → \(nextIndex, privacy: .public): \(error, privacy: .public)")
            }
        }
    }
}
