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
    /// Chunk start times (§8.12): wall-clock at the anchor, advanced by the monotonic clock — a wall-clock
    /// step (NTP, a manual change) mid-recording cannot bend the timeline.
    private let clock: MonotonicWallClock
    private let onChunkFinalized: @MainActor (FinalizedChunk) -> Void
    /// After every successful rotation, once the finalized chunk was handed over: the coordinator
    /// refreshes the sentinel's liveness there (§8.3).
    public var onRotated: (@MainActor () -> Void)?
    /// A rotation threw: the current chunk keeps recording under its index (§8.7). The coordinator
    /// raises `rotationFailed`, and a helper that is no longer capturing takes the crash path.
    public var onRotationFailed: (@MainActor (Error) -> Void)?

    /// - Parameter startIndex: the index of the chunk being recorded now. A resumed session starts
    ///   past its settled chunks; restarting at 0 made the last chunk collide with the seeded
    ///   chunk 0, and every word after the resume was dropped as a "duplicate".
    public init(
        captureClient: any ChunkRotationClient,
        outputDirectory: String,
        sessionBaseName: String,
        chunkDurationMinutes: Int,
        startIndex: Int = 0,
        clock: MonotonicWallClock,
        onChunkFinalized: @MainActor @escaping (FinalizedChunk) -> Void
    ) {
        self.captureClient = captureClient
        self.outputDirectory = outputDirectory
        self.sessionBaseName = sessionBaseName
        self.chunkDuration = TimeInterval(chunkDurationMinutes * 60)
        self.currentChunkIndex = startIndex
        self.clock = clock
        self.currentChunkStartTime = clock.anchorWall
        self.onChunkFinalized = onChunkFinalized
    }

    /// Anchored at `startTime`, now. A resume passes the CURRENT time: the monotonic clock cannot be
    /// persisted, so a relaunch re-anchors — never at the seeded `meetingStart` (C10).
    public convenience init(
        captureClient: any ChunkRotationClient,
        outputDirectory: String,
        sessionBaseName: String,
        chunkDurationMinutes: Int,
        startIndex: Int = 0,
        startTime: Date,
        onChunkFinalized: @MainActor @escaping (FinalizedChunk) -> Void
    ) {
        self.init(captureClient: captureClient, outputDirectory: outputDirectory, sessionBaseName: sessionBaseName,
                  chunkDurationMinutes: chunkDurationMinutes, startIndex: startIndex,
                  clock: .start(now: startTime), onChunkFinalized: onChunkFinalized)
    }

    /// A rotator torn down without `stop()` (the pipeline's teardown drops it) takes its timer with it (L10
    /// review 54). On the main actor, where the timer was added to the run loop.
    isolated deinit {
        timer?.invalidate()
    }

    /// Test seam (`@testable import`): the active rotation timer, so tests can confirm it was
    /// added to the run loop in `.common` mode (#197) without waiting on a real firing.
    var activeTimerForTesting: Timer? { timer }

    /// The base name for the current chunk's WAV files.
    public var currentBaseName: String { "\(sessionBaseName)-\(currentChunkIndex)" }

    /// Where this live session's chunks are: a salvage without the sentinel still finds them (L round 5).
    public var sessionLocation: (outputDir: URL, sessionId: String) {
        (URL(fileURLWithPath: outputDirectory), sessionBaseName)
    }

    /// Info about the current (in-progress) chunk for final processing.
    public var currentChunkInfo: (index: Int, startTime: Date) {
        (index: currentChunkIndex, startTime: currentChunkStartTime)
    }

    /// The chunk being recorded began before this rotator existed — a re-attach after an app crash (L
    /// follow-up 30): its start time is when its file was created, not now.
    public func adoptCurrentChunk(startedAt date: Date) {
        currentChunkStartTime = date
    }

    /// When the chunk being recorded is due to rotate: its start plus one chunk.
    public var currentChunkDue: Date { currentChunkStartTime.addingTimeInterval(chunkDuration) }

    /// Recover from a live XPC crash: advance to the next chunk index so the post-crash recording
    /// continues at a fresh chunk, and return the plan whose names the caller uses for the orphan
    /// (the current index) and the recovery segment. The caller MUST enqueue the orphan chunk
    /// (using `currentBaseName` / `currentChunkInfo`) BEFORE calling this — once it returns, the
    /// index has advanced (#92). The new chunk starts at `now`, by default the rotator's monotonic
    /// clock (L11 review 68).
    @discardableResult
    public func recoverFromCrash(now: Date? = nil) -> ChunkRecoveryPlan {
        // A timed-out rotation the helper completed late is settled first: the orphan is the chunk the
        // helper was really writing (L9 review 46).
        reconcileLateRotation()
        let planned = chunkRecoveryPlan(sessionBaseName: sessionBaseName, currentChunkIndex: currentChunkIndex)
        // The recovery segment's name must not be a file already on disk (same rule as rotate()).
        let recoveryIndex = nextFreeIndex(after: currentChunkIndex)
        let plan = recoveryIndex == planned.recoveryIndex ? planned : ChunkRecoveryPlan(
            orphanIndex: planned.orphanIndex, recoveryIndex: recoveryIndex,
            orphanBaseName: planned.orphanBaseName, recoveryBaseName: "\(sessionBaseName)-\(recoveryIndex)")
        currentChunkIndex = plan.recoveryIndex
        currentChunkStartTime = now ?? clock.now()
        lateAttempts = []   // the crashed helper completes nothing more
        Logger.audio.info("ChunkRotator recovered: orphan chunk \(plan.orphanIndex, privacy: .public), resuming at \(plan.recoveryIndex, privacy: .public)")
        return plan
    }

    /// Start the rotation timer. The first rotation is one chunk from now — or at `firstRotationAt`: a re-attach
    /// rotates the live chunk when IT is due, at once when that has passed (L review 77).
    public func start(firstRotationAt: Date? = nil) {
        Logger.audio.info("ChunkRotator started — interval: \(self.chunkDuration, privacy: .public)s, base: \(self.sessionBaseName, privacy: .sensitive)")
        let firstFire = firstRotationAt ?? Date().addingTimeInterval(chunkDuration)
        let newTimer = Timer(fire: firstFire, interval: chunkDuration, repeats: true) { [weak self] timer in
            // A rotator torn down without `stop()` takes its timer with it: never a repeating timer left
            // waking an idle app (L10 review 54). The run loop calls this on the main thread, where it was added.
            guard self != nil else {
                timer.invalidate()
                return
            }
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

    /// The rotation in flight. Each one chains after the previous, so two never overlap (both would
    /// name the same next chunk).
    private var rotation: Task<Void, Never>?
    /// Rotations the helper did not answer in time (§8.8), oldest first: the chunk index each asked it to open,
    /// all asked while this rotator still named the current chunk. One may still complete in the helper — which
    /// then writes that chunk while this rotator names the old one — so they are settled before the next
    /// rotation, at Stop and at a crash (L9 review 46).
    private var lateAttempts: [Int] = []

    private func rotate() {
        let previous = rotation
        rotation = Task { await previous?.value; await performRotation() }
    }

    /// Returns once no rotation is in flight: Stop must not ask the helper to stop while it swaps the
    /// chunk files (council B-I3). The caller stops the timer first.
    public func awaitRotationInFlight() async {
        await rotation?.value
    }

    /// An immediate rotation, off the timer's schedule (wake, tests).
    public func rotateNow() {
        rotate()
    }

    /// Test seam: one rotation, awaited.
    func rotateForTesting() async {
        await performRotation()
    }

    /// A rotation that timed out may have completed in the helper after all: if a chunk it asked for is on
    /// disk, the helper sealed the current chunk and is writing that one. Then every sealed chunk is emitted
    /// from ITS OWN files, in order, and the helper's index adopted — each chunk processed once, from its own
    /// audio. Called before every rotation, by Stop (after the helper's stop) and by a crash recovery.
    /// Returns whether it reconciled; an attempt that did not complete (yet) stays pending.
    @discardableResult
    public func reconcileLateRotation() -> Bool {
        let opened = lateAttempts.filter { fileExists(index: $0, suffix: ".wav") }
        guard let writing = opened.last else { return false }
        Logger.audio.error("ChunkRotator: a timed-out rotation of chunk \(self.currentChunkIndex, privacy: .public) completed late — the helper is writing \(writing, privacy: .public)")
        emitSealed(opened.dropLast(), last: nil)
        currentChunkIndex = writing
        // When the helper opened it: the file's creation, never before the chunk it sealed began.
        currentChunkStartTime = max(creationDate(index: writing) ?? clock.now(), currentChunkStartTime)
        // Attempts made after the one that opened `writing` would seal IT if they complete: still pending.
        lateAttempts = lateAttempts.filter { $0 > writing }
        onRotated?()
        return true
    }

    /// Emits the current chunk from its own files, then each chunk in `between` (opened and sealed by late
    /// rotations) from its own files, then — when the helper's reply names it — `last` from the reply.
    private func emitSealed(_ between: ArraySlice<Int>, last: (index: Int, paths: (systemPath: String, micPath: String))?) {
        var start = currentChunkStartTime
        onChunkFinalized(ownFiles(index: currentChunkIndex, startTime: start))
        for index in between {
            start = max(creationDate(index: index) ?? start, start)
            onChunkFinalized(ownFiles(index: index, startTime: start))
        }
        if let last {
            start = max(creationDate(index: last.index) ?? start, start)
            onChunkFinalized(FinalizedChunk(index: last.index, systemPath: last.paths.systemPath, micPath: last.paths.micPath, startTime: start))
        }
    }

    private func ownFiles(index: Int, startTime: Date) -> FinalizedChunk {
        let base = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(sessionBaseName)-\(index)").path
        return FinalizedChunk(index: index, systemPath: base + ".wav", micPath: base + "_mic.wav", startTime: startTime)
    }

    private func creationDate(index: Int) -> Date? {
        let path = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(sessionBaseName)-\(index).wav").path
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }

    private func performRotation() async {
        reconcileLateRotation()
        let oldIndex = currentChunkIndex
        let oldStartTime = currentChunkStartTime
        // Past every timed-out attempt's name too: the helper may still create it (L9 review 46).
        let nextIndex = nextFreeIndex(after: max(oldIndex, lateAttempts.max() ?? oldIndex))
        let nextBaseName = "\(sessionBaseName)-\(nextIndex)"

        Logger.audio.info("Rotating chunk \(oldIndex, privacy: .public) → \(nextIndex, privacy: .public)")

        do {
            let paths = try await captureClient.rotateChunk(
                outputDirectory: outputDirectory,
                newBaseName: nextBaseName
            )
            // The helper answered, so every earlier attempt is settled. It sealed the chunk it was writing:
            // normally the current one — but if a timed-out attempt completed just before (after the check
            // above), the reply names that attempt's chunk, and the chunks before it come from their own files.
            let sealedName = URL(fileURLWithPath: paths.systemPath).lastPathComponent
            if let late = lateAttempts.firstIndex(where: { "\(sessionBaseName)-\($0).wav" == sealedName }) {
                let between = lateAttempts[..<late].filter { fileExists(index: $0, suffix: ".wav") }
                emitSealed(between[...], last: (lateAttempts[late], paths))
            } else {
                onChunkFinalized(FinalizedChunk(index: oldIndex, systemPath: paths.systemPath, micPath: paths.micPath,
                                                startTime: oldStartTime))
            }
            lateAttempts = []
            self.currentChunkIndex = nextIndex
            self.currentChunkStartTime = clock.now()
            self.onRotated?()
        } catch {
            Logger.audio.error("ChunkRotator: failed to rotate chunk \(oldIndex, privacy: .public) → \(nextIndex, privacy: .public): \(error, privacy: .private)")
            // Timed out: the helper may still complete it — remembered, settled before the next rotation.
            if error is CaptureCallTimeout { lateAttempts.append(nextIndex) }
            onRotationFailed?(error)
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
        [".wav", "_mic.wav", ".m4a"].contains { fileExists(index: index, suffix: $0) }
    }

    private func fileExists(index: Int, suffix: String) -> Bool {
        let base = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(sessionBaseName)-\(index)")
        return FileManager.default.fileExists(atPath: base.path + suffix)
    }
}
