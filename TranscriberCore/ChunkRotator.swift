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
    /// Every look at the session folder — which chunk files are there, when one was created — runs here: off the main
    /// actor, bounded (L review 158). A share that stops answering mid-recording never freezes the UI at a rotation.
    public var folderReads: FolderReads = .shared
    /// The bound on one look at the folder. Tests shorten it.
    var folderProbeSeconds: Double = 2
    /// The client's bound on one rotate (§8.8): what a rotation already sent may still take.
    public nonisolated static let rotateCallSeconds: Double = 10
    /// The longest a rotation in flight can take (L review 208): its look, the rotate, and the look on a late reply — what a
    /// Stop waits for, with a second's margin.
    public var rotationBoundSeconds: Double { Self.rotateCallSeconds + 2 * folderProbeSeconds + 1 }
    /// A look at the folder did not answer: its file checks were skipped, and the step went on from the counter (L
    /// review 158). The coordinator records it. The argument names the step.
    public var onFolderNotAnswering: (@MainActor (String) -> Void)?
    /// Late chunks the Stop could not check — a look did not answer — by index (L review 213): said, never dropped silently.
    public var onLateChunksUnchecked: (@MainActor ([Int]) -> Void)?

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
    ///
    /// The folder is looked at off the main actor, bounded (L review 158): one that does not answer skips the look —
    /// nothing late is reconciled, and the recovery index comes from the counter.
    @discardableResult
    public func recoverFromCrash(now: Date? = nil) async -> ChunkRecoveryPlan {
        // FIRST, before the look's await: a rotation still in flight to the crashed helper completes nothing (L review
        // 115) — neither its timeout remembered nor its reply applied.
        generation += 1
        // A timed-out rotation the helper completed late is settled first: the orphan is the chunk the
        // helper was really writing (L9 review 46). Not a rotation (L review 118).
        let look = await look(freeAfterCurrent: true, includeLate: false, "crash recovery")
        if let look {
            applyReconcile(look, announce: false)
            settleUnchecked(look)
        }
        let planned = chunkRecoveryPlan(sessionBaseName: sessionBaseName, currentChunkIndex: currentChunkIndex)
        // The recovery segment's name must not be a file already on disk (same rule as rotate()) — nor, when the look did
        // not answer, any name ever asked for (L review 207): the shared counter is past them all.
        let counter = max(counterNext, planned.recoveryIndex)
        let recoveryIndex = max(look?.nextFree ?? counter, counter)
        let plan = recoveryIndex == planned.recoveryIndex ? planned : ChunkRecoveryPlan(
            orphanIndex: planned.orphanIndex, recoveryIndex: recoveryIndex,
            orphanBaseName: planned.orphanBaseName, recoveryBaseName: "\(sessionBaseName)-\(recoveryIndex)")
        currentChunkIndex = plan.recoveryIndex
        currentChunkStartTime = now ?? clock.now()
        lateAttempts = []   // the crashed helper completes nothing more
        lateAskedAt = [:]
        Logger.audio.info("ChunkRotator recovered: orphan chunk \(plan.orphanIndex, privacy: .public), resuming at \(plan.recoveryIndex, privacy: .public)")
        return plan
    }

    /// Start the rotation timer. The first rotation is one chunk from now — or at `firstRotationAt`: a re-attach
    /// rotates the live chunk when IT is due, at once when that has passed (L review 77).
    public func start(firstRotationAt: Date? = nil) {
        stopped = false
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

    /// Stop the timer. Does NOT finalize the current chunk. A rotation in flight that has not sent its rotate yet never
    /// sends it (L review 208): it checks after each look.
    public func stop() {
        stopped = true
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
    /// When each late attempt was asked for (L review 212): a chunk the helper opened no earlier — the floor of its start
    /// when its file's creation cannot be read, so chunks never overlap.
    private var lateAskedAt: [Int: Date] = [:]
    /// The highest index ever asked for, whatever the rotate answered (L review 207): the helper may have created it.
    private var highestAsked: Int?
    /// Late attempts a look could not check — below a chunk the helper sealed later, so opened and sealed if the helper got
    /// to them (L review 213). Settled at the next look that answers: emitted from their own files, or dropped when the helper
    /// never opened them. At a Stop that cannot look, said.
    private var uncheckedLate: [Int] = []
    /// `stop()` was called and no `start()` since (L review 208).
    private var stopped = false
    /// Bumped by a crash recovery: a rotation still in flight to the dead helper answers for a helper that is gone
    /// — its timeout is never remembered, its reply never applied (L review 115).
    private var generation = 0

    /// The next index when no look answers (L review 207): past the current chunk, past every late attempt, and past EVERY
    /// index ever asked for — whatever the error. A crash recovery and a rotation share it, so the two fallbacks agree, and
    /// neither ever names a chunk the helper may have created (its `createFile` would truncate that chunk's audio).
    private var counterNext: Int {
        max(currentChunkIndex, lateAttempts.max() ?? currentChunkIndex, highestAsked ?? currentChunkIndex) + 1
    }

    /// When chunk `index` began, no earlier than `previous` (L review 212): its file's creation when a look read it, else —
    /// a late attempt — when it was asked for; never before the chunk emitted before it.
    private func chunkStart(of index: Int, created: [Int: Date], after previous: Date) -> Date {
        let asked = lateAskedAt[index]
        return max(created[index] ?? asked ?? previous, asked ?? previous, previous)
    }

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
    /// Returns whether it reconciled; an attempt that did not complete (yet) stays pending — and so does every one
    /// when the folder does not answer the look (L review 158). `announce`: `onRotated` runs — only before a rotation,
    /// never at Stop or at a crash, which are not rotations (L review 118). Off unless asked for (L review 172): only
    /// `performRotation` announces, through its own reconcile.
    @discardableResult
    public func reconcileLateRotation(announce: Bool = false) async -> Bool {
        guard !lateAttempts.isEmpty || !uncheckedLate.isEmpty,
              let look = await look(freeAfterCurrent: false, includeLate: true, "reconcile") else { return false }
        settleUnchecked(look)
        return applyReconcile(look, announce: announce)
    }

    /// The reconcile, from a look taken at the folder. Only attempts still pending count: the look may be older than
    /// a step that settled some meanwhile.
    @discardableResult
    private func applyReconcile(_ look: FolderLook, announce: Bool) -> Bool {
        let opened = look.opened.filter { lateAttempts.contains($0) }
        guard let writing = opened.last else { return false }
        Logger.audio.error("ChunkRotator: a timed-out rotation of chunk \(self.currentChunkIndex, privacy: .public) completed late — the helper is writing \(writing, privacy: .public)")
        emitSealed(opened.dropLast(), last: nil, created: look.created)
        currentChunkIndex = writing
        // When the helper opened it: the file's creation — or when it was asked for — never before the chunk it sealed began.
        currentChunkStartTime = look.created[writing] == nil && lateAskedAt[writing] == nil
            ? max(clock.now(), currentChunkStartTime) : chunkStart(of: writing, created: look.created, after: currentChunkStartTime)
        // Attempts made after the one that opened `writing` would seal IT if they complete: still pending.
        lateAttempts = lateAttempts.filter { $0 > writing }
        if announce { onRotated?() }
        return true
    }

    /// The Stop's last chunk (L review 113): the one the helper's stop reply NAMES — never one chunk's audio under
    /// another's index. The reply is read FIRST (L review 169): it says which chunk the helper sealed, while a late
    /// attempt's files on disk only say that a swap BEGAN — an overrun swap abandoned at the Stop leaves its files, yet the
    /// helper sealed the chunk it was writing all along.
    /// - It names the current chunk: the late attempts never took over — dropped without a file check.
    /// - It names a later chunk of this session (late attempt k): the current chunk, and every late attempt below k whose
    ///   file the helper opened, are emitted from their own files through `onChunkFinalized`; k is returned, for the
    ///   caller to process last.
    /// - It names an earlier chunk of this session: that chunk, with its own file's start.
    /// - Only a name that is not this session's falls back to the file check (a late rotation reconciled from its
    ///   files); the current index is kept (logged).
    /// The folder is looked at off the main actor, bounded (L review 158); one that does not answer reconciles nothing,
    /// and the named chunk starts where the last one emitted did.
    public func lastChunkAtStop(systemPath: String, micPath: String) async -> FinalizedChunk {
        let sealed = URL(fileURLWithPath: systemPath).lastPathComponent
        guard let named = chunkIndex(named: sealed) else {
            let look = await look(freeAfterCurrent: false, includeLate: true, "stop")
            if let look {
                settleUnchecked(look)
                applyReconcile(look, announce: false)
            } else {
                uncheckedLate += lateAttempts   // never checked, never silently dropped (L review 213)
            }
            Logger.audio.error("ChunkRotator: the stop sealed a file this session does not name — kept as chunk \(self.currentChunkIndex, privacy: .public)")
            reportUnchecked()
            return FinalizedChunk(index: currentChunkIndex, systemPath: systemPath, micPath: micPath, startTime: currentChunkStartTime)
        }
        guard named != currentChunkIndex else {
            if !lateAttempts.isEmpty {
                Logger.audio.info("ChunkRotator: the stop sealed chunk \(named, privacy: .public) — the timed-out rotation(s) to \(self.lateAttempts, privacy: .public) never took over; dropped without a file check")
            }
            lateAttempts = []
            lateAskedAt = [:]
            // Chunks an earlier rotation could not check are settled now — or said (L review 213).
            if !uncheckedLate.isEmpty, let look = await look(freeAfterCurrent: false, includeLate: false, "stop") { settleUnchecked(look) }
            reportUnchecked()
            return FinalizedChunk(index: named, systemPath: systemPath, micPath: micPath, startTime: currentChunkStartTime)
        }
        Logger.audio.error("ChunkRotator: the stop sealed chunk \(named, privacy: .public) while chunk \(self.currentChunkIndex, privacy: .public) was named — each labelled by its own index")
        // The named chunk's file — and a late attempt's below it — say when each began: one look, bounded.
        let look = await look(freeAfterCurrent: false, includeLate: true, extra: [named], "stop")
        if let look { settleUnchecked(look) }
        let created = look?.created ?? [:]
        let start: Date
        if named > currentChunkIndex {
            let below = lateAttempts.filter { $0 < named }
            if look == nil { uncheckedLate += below }   // could not be checked: said, never dropped (L review 213)
            let between = below.filter { look?.opened.contains($0) == true }
            let lastEmitted = emitSealed(between[...], last: nil, created: created)
            start = chunkStart(of: named, created: created, after: lastEmitted)
        } else {
            // An earlier chunk than the one named: its own file's creation, never the current chunk's start.
            start = min(created[named] ?? currentChunkStartTime, currentChunkStartTime)
        }
        currentChunkIndex = named
        currentChunkStartTime = start
        lateAttempts = []
        lateAskedAt = [:]
        reportUnchecked()
        return FinalizedChunk(index: named, systemPath: systemPath, micPath: micPath, startTime: start)
    }

    /// The late chunks no look could check, emitted from their own files when this look found them — the helper opened
    /// them — and dropped when it did not (L review 213). Each starts no earlier than it was asked for (L review 212).
    private func settleUnchecked(_ look: FolderLook) {
        guard !uncheckedLate.isEmpty else { return }
        for index in uncheckedLate.sorted() {
            if look.uncheckedOpened.contains(index) {
                Logger.audio.error("ChunkRotator: late chunk \(index, privacy: .public), unchecked until now, is on disk — processed from its own files")
                onChunkFinalized(ownFiles(index: index, startTime: look.created[index] ?? lateAskedAt[index] ?? currentChunkStartTime))
            } else {
                Logger.audio.info("ChunkRotator: late chunk \(index, privacy: .public) was never opened — nothing to process")
            }
        }
        uncheckedLate = []
    }

    /// At a Stop, the late chunks still unchecked are said (L review 213): the caller records and shows them.
    private func reportUnchecked() {
        guard !uncheckedLate.isEmpty else { return }
        let indices = uncheckedLate.sorted()
        uncheckedLate = []
        Logger.audio.error("ChunkRotator: late chunk(s) \(indices, privacy: .public) could not be checked — the folder did not answer")
        onLateChunksUnchecked?(indices)
    }

    /// `<session>-<n>.wav` → n; nil for any other name.
    private func chunkIndex(named file: String) -> Int? {
        let prefix = "\(sessionBaseName)-", suffix = ".wav"
        guard file.hasPrefix(prefix), file.hasSuffix(suffix) else { return nil }
        return Int(file.dropFirst(prefix.count).dropLast(suffix.count))
    }

    /// Emits the current chunk from its own files, then each chunk in `between` (opened and sealed by late
    /// rotations) from its own files, then — when the helper's reply names it — `last` from the reply. `created`: the
    /// chunk files' creation dates, as a look at the folder found them. Returns the last emitted chunk's start.
    @discardableResult
    private func emitSealed(_ between: ArraySlice<Int>, last: (index: Int, paths: (systemPath: String, micPath: String))?,
                            created: [Int: Date]) -> Date {
        var start = currentChunkStartTime
        onChunkFinalized(ownFiles(index: currentChunkIndex, startTime: start))
        for index in between {
            start = chunkStart(of: index, created: created, after: start)
            onChunkFinalized(ownFiles(index: index, startTime: start))
        }
        if let last {
            start = chunkStart(of: last.index, created: created, after: start)
            onChunkFinalized(FinalizedChunk(index: last.index, systemPath: last.paths.systemPath, micPath: last.paths.micPath, startTime: start))
        }
        return start
    }

    private func ownFiles(index: Int, startTime: Date) -> FinalizedChunk {
        let base = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(sessionBaseName)-\(index)").path
        return FinalizedChunk(index: index, systemPath: base + ".wav", micPath: base + "_mic.wav", startTime: startTime)
    }

    private func performRotation() async {
        let generation = self.generation
        guard !stopped else {
            Logger.audio.info("ChunkRotator: stopped — the rotation is dropped")
            return
        }
        // One look at the folder, off the main actor and bounded (L review 158): the late attempts to settle, and the
        // next free name. A folder that does not answer is skipped — the counter names the next chunk — never waited on.
        let look = await look(freeAfterCurrent: true, includeLate: true, "rotation")
        guard generation == self.generation else {
            Logger.audio.info("ChunkRotator: a crash recovery ran while the rotation looked at its folder — the rotation is dropped")
            return
        }
        // Stopped while it looked (L review 208): a Stop owns the helper now — this rotation never sends its rotate.
        guard !stopped else {
            Logger.audio.info("ChunkRotator: stopped while the rotation looked at its folder — no rotate is sent")
            return
        }
        if let look {
            settleUnchecked(look)
            applyReconcile(look, announce: true)
        }
        let oldIndex = currentChunkIndex
        let oldStartTime = currentChunkStartTime
        // Past every timed-out attempt's name and every name ever asked for: the helper may still create it (L9 review 46,
        // L review 207).
        let counter = counterNext
        let nextIndex = max(look?.nextFree ?? counter, counter)
        let nextBaseName = "\(sessionBaseName)-\(nextIndex)"

        Logger.audio.info("Rotating chunk \(oldIndex, privacy: .public) → \(nextIndex, privacy: .public)")
        // Asked for from here, whatever the answer (L reviews 207, 212).
        highestAsked = max(highestAsked ?? nextIndex, nextIndex)
        let askedAt = clock.now()

        do {
            let paths = try await captureClient.rotateChunk(
                outputDirectory: outputDirectory,
                newBaseName: nextBaseName
            )
            guard generation == self.generation else {
                Logger.audio.error("ChunkRotator: a rotation answered after a crash recovery — the dead helper's reply is dropped")
                return
            }
            // The helper answered, so every earlier attempt is settled. It sealed the chunk it was writing:
            // normally the current one — but if a timed-out attempt completed just before (after the check
            // above), the reply names that attempt's chunk, and the chunks before it come from their own files.
            let sealedName = URL(fileURLWithPath: paths.systemPath).lastPathComponent
            if let late = lateAttempts.firstIndex(where: { "\(sessionBaseName)-\($0).wav" == sealedName }) {
                // Rare: a late attempt completed just before this one. Its chunks' files are looked at again — bounded;
                // unanswered, only the current chunk and the reply's are emitted.
                let attempts = lateAttempts
                let again = await self.look(freeAfterCurrent: false, includeLate: true, "rotation reply")
                if let again { settleUnchecked(again) } else { uncheckedLate += attempts[..<late] }   // L review 213
                let between = attempts[..<late].filter { again?.opened.contains($0) == true }
                emitSealed(between[...], last: (attempts[late], paths), created: again?.created ?? [:])
            } else {
                onChunkFinalized(FinalizedChunk(index: oldIndex, systemPath: paths.systemPath, micPath: paths.micPath,
                                                startTime: oldStartTime))
            }
            lateAttempts = []
            lateAskedAt = [:]
            self.currentChunkIndex = nextIndex
            self.currentChunkStartTime = clock.now()
            self.onRotated?()
        } catch {
            guard generation == self.generation else {
                Logger.audio.info("ChunkRotator: a rotation to the helper a crash recovery replaced failed — not remembered")
                return
            }
            Logger.audio.error("ChunkRotator: failed to rotate chunk \(oldIndex, privacy: .public) → \(nextIndex, privacy: .public): \(error, privacy: .private)")
            // Timed out — the client's deadline, or the helper's own "Rotation timed out" (its writer swap overran
            // and may land late; L review 91b): the helper may still complete it — remembered, settled before the
            // next rotation. A refusal, not a dead capture.
            if error is CaptureCallTimeout || error.localizedDescription == CaptureReplies.rotationTimedOut {
                lateAttempts.append(nextIndex)
                lateAskedAt[nextIndex] = askedAt
            }
            onRotationFailed?(error)
        }
    }

    // MARK: - Looking at the folder (L review 158)

    /// What one look at the session folder found.
    struct FolderLook: Sendable {
        /// The late attempts whose chunk file is on disk: the helper opened them.
        var opened: [Int] = []
        /// The unchecked late chunks (L review 213) whose file is on disk.
        var uncheckedOpened: Set<Int> = []
        /// The creation dates of the chunk files looked at (the opened attempts, and any asked for).
        var created: [Int: Date] = [:]
        /// The first index past the current chunk — once the opened attempts are settled, and past every attempt still
        /// pending — whose chunk files are not on disk. The helper CREATES the file it is given, so reusing a name
        /// overwrites that chunk's audio: the file a resumed session is still writing, or an unprocessed orphan.
        var nextFree: Int?
    }

    /// One look at the folder, off the main actor and bounded (L review 158); nil — said through
    /// `onFolderNotAnswering` — when it did not answer.
    private func look(freeAfterCurrent: Bool, includeLate: Bool, extra: [Int] = [], _ step: String) async -> FolderLook? {
        let dir = outputDirectory, base = sessionBaseName, current = currentChunkIndex, late = lateAttempts, unchecked = uncheckedLate
        let answer = await folderReads.read("rotation: chunk files", folder: dir, key: dir + "#chunk-rotator", seconds: folderProbeSeconds) {
            Self.look(dir: dir, base: base, current: current, late: late, extra: extra, unchecked: unchecked,
                      freeAfterCurrent: freeAfterCurrent, includeLate: includeLate)
        }
        if answer == nil {
            Logger.audio.error("ChunkRotator: the recording folder did not answer (\(step, privacy: .public)) — its file checks are skipped")
            onFolderNotAnswering?(step)
        }
        return answer
    }

    /// The look itself: blocking file-system work, run only through `folderReads`.
    nonisolated static func look(dir: String, base: String, current: Int, late: [Int], extra: [Int], unchecked: [Int] = [],
                                 freeAfterCurrent: Bool, includeLate: Bool) -> FolderLook {
        let folder = URL(fileURLWithPath: dir)
        func path(_ index: Int, _ suffix: String) -> String { folder.appendingPathComponent("\(base)-\(index)").path + suffix }
        func exists(_ index: Int, _ suffix: String) -> Bool { FileManager.default.fileExists(atPath: path(index, suffix)) }
        var look = FolderLook()
        look.opened = late.filter { exists($0, ".wav") }
        look.uncheckedOpened = Set(unchecked.filter { exists($0, ".wav") })
        for index in Set(look.opened + extra + look.uncheckedOpened) {
            look.created[index] = (try? FileManager.default.attributesOfItem(atPath: path(index, ".wav")))?[.creationDate] as? Date
        }
        guard freeAfterCurrent else { return look }
        // As the reconcile will leave it: the newest opened attempt is the current chunk, later attempts still pending.
        let writing = look.opened.last
        let now = writing ?? current
        let pending = includeLate ? late.filter { $0 > (writing ?? Int.min) } : []
        var candidate = max(now, pending.max() ?? now) + 1
        // Every artefact a chunk leaves: its two WAVs and, once processed, its archive.
        while [".wav", "_mic.wav", ".m4a"].contains(where: { exists(candidate, $0) }) {
            Logger.audio.error("ChunkRotator: chunk \(candidate, privacy: .public) is already on disk — skipping to the next free name")
            candidate += 1
        }
        look.nextFree = candidate
        return look
    }
}
