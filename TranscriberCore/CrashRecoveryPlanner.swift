import Foundation
import os

public enum CrashRecoveryPlanner {
    public struct OrphanChunk: Equatable {
        public let index: Int; public let baseName: String
        public init(index: Int, baseName: String) { self.index = index; self.baseName = baseName }
    }
    /// Scan `outputDirectory` for `<sessionId>-N.wav` and `<sessionId>-N.m4a` chunk files (excluding
    /// the `_mic.wav` companion), returning each discovered index once, alongside its base name (no
    /// extension) and whether a WAV exists for it. Shared by `orphanChunks` and `nextFreeChunkIndex`
    /// so both use identical name parsing.
    private static func onDiskChunkIndices(outputDirectory: URL, sessionId: String) -> [(index: Int, baseName: String, hasWav: Bool)] {
        listedChunkIndices(outputDirectory: outputDirectory, sessionId: sessionId) ?? []
    }

    /// `onDiskChunkIndices`, nil when the folder does not list: unknown, never "none".
    private static func listedChunkIndices(outputDirectory: URL, sessionId: String) -> [(index: Int, baseName: String, hasWav: Bool)]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path) else { return nil }
        let prefix = "\(sessionId)-"
        var found: [Int: (baseName: String, hasWav: Bool)] = [:]
        for name in names where name.hasPrefix(prefix) && !name.hasSuffix("_mic.wav") {
            let isWav = name.hasSuffix(".wav")
            guard isWav || name.hasSuffix(".m4a") else { continue }
            let stem = String(name.dropLast(4))
            guard let idx = Int(stem.dropFirst(prefix.count)) else { continue }
            found[idx] = (stem, isWav || (found[idx]?.hasWav ?? false))
        }
        return found.map { (index: $0.key, baseName: $0.value.baseName, hasWav: $0.value.hasWav) }
    }

    /// Every archive of `sessionId` in the folder, registered or not: `<id>.m4a` (a merge) and
    /// `<id>-<n>.m4a` (chunks), by the same name rule as the orphan scan. What a quota pass must never
    /// delete while the session is being processed (round 8 item 1).
    public static func sessionArchives(outputDirectory: URL, sessionId: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
        return names.filter { isArchive($0, of: sessionId) }.map { outputDirectory.appendingPathComponent($0) }
    }

    /// The name rule of `sessionArchives`: `<id>.m4a` or `<id>-<n>.m4a`. An id can start another (`a`, `a-2`): `a-2.m4a` is
    /// then `a`'s chunk 2 or `a-2`'s merge, and counts as both (#230) — a name is only ever kept by this, never deleted.
    static func isArchive(_ name: String, of sessionId: String) -> Bool {
        guard name.hasSuffix(".m4a") else { return false }
        if name == "\(sessionId).m4a" { return true }
        let prefix = "\(sessionId)-"
        guard name.hasPrefix(prefix) else { return false }
        return Int(name.dropFirst(prefix.count).dropLast(".m4a".count)) != nil
    }

    /// Chunks on disk that `session.json` does not hold. An archive with no WAV counts (C-I4: a crash
    /// between archiving a chunk and writing session.json left only its `.m4a`; `ChunkProcessor`
    /// transcribes it from the archive). A FINALIZED session has no orphans at all: its WAVs (kept by
    /// preserve_source_wav, or after a failed recognition) and archives are its record's audio, and
    /// re-ingesting them re-finalized over the finished transcript (R2a item 12).
    public static func orphanChunks(outputDirectory: URL, sessionId: String, completedIndices: Set<Int>) -> [OrphanChunk] {
        guard !isFinalized(outputDirectory: outputDirectory, sessionId: sessionId) else { return [] }
        return unregisteredChunks(outputDirectory: outputDirectory, sessionId: sessionId, completedIndices: completedIndices)
    }

    /// Chunks on disk not in `completedIndices`, finalized or not: what a rebuild of a finalized
    /// session with an unreadable transcript must also take (round 4 item 3).
    static func unregisteredChunks(outputDirectory: URL, sessionId: String, completedIndices: Set<Int>) -> [OrphanChunk] {
        onDiskChunkIndices(outputDirectory: outputDirectory, sessionId: sessionId)
            .filter { !completedIndices.contains($0.index) }
            .map { OrphanChunk(index: $0.index, baseName: $0.baseName) }
            .sorted { $0.index < $1.index }
    }

    /// Whether `sessionId` was finalized: its durable marker, or — for a session finalized before the
    /// marker existed — its transcript `<sessionId>.json`. Recovery never re-ingests or re-finalizes
    /// such a session (R2a item 12).
    public static func isFinalized(outputDirectory: URL, sessionId: String) -> Bool {
        SessionState.isMarkedFinalized(directory: outputDirectory, sessionId: sessionId)
            || FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("\(sessionId).json").path)
    }

    /// For a finalized session whose transcript verifies: remove its leftover session state, sweep its
    /// temp files and re-write a missing TXT/SRT — silently, with no rename dialog and no summary.
    /// What a launch that finds such a session's recovery file calls (stream L's gate), instead of a
    /// full recovery (round 4 item 1). False when the session is not finalized with a readable
    /// transcript; nothing is touched then.
    @discardableResult
    public static func cleanupFinalized(outputDirectory: URL, sessionId: String) -> Bool {
        let transcript = outputDirectory.appendingPathComponent("\(sessionId).json")
        guard isFinalized(outputDirectory: outputDirectory, sessionId: sessionId), TranscriptAssembler.verifies(transcript) else { return false }
        SessionState.sweepTemporaries(directory: outputDirectory, sessionId: sessionId)
        SessionState.delete(directory: outputDirectory, sessionId: sessionId)
        TranscriptWriter.writeFormatFileIfMissing(fromJSON: transcript)
        return true
    }

    /// A session that ended with nothing to salvage — no chunk in its state, no chunk file on disk — leaves no state behind
    /// (#323 follow-up): its `session.json` is written at its start (#294), so without this it would linger, be moved aside by
    /// the next recording in the folder (a spurious `session_file_displaced` in that unrelated record) and keep that id's
    /// archives from the storage limit for good. Fail-closed: a finalized session (its own cleanup decides), a chunk file of
    /// this id on disk, or state that holds a chunk or cannot be read keeps it all, logged (`SessionState.deleteIfEmpty`).
    /// Call it only once nothing of the session is still being processed. Blocking file work: only through `FolderReads`.
    @discardableResult
    public static func removeEmptySessionState(outputDirectory: URL, sessionId: String) -> Bool {
        if isFinalized(outputDirectory: outputDirectory, sessionId: sessionId) {
            Logger.state.info("An ended session with no chunk is marked finalized — its state is left to its own cleanup")
            return false
        }
        // A folder that does not list says nothing about its chunk files: never "none" (fail-closed).
        guard let onDisk = listedChunkIndices(outputDirectory: outputDirectory, sessionId: sessionId) else {
            Logger.state.error("An ended session's folder could not be listed — its state is kept")
            return false
        }
        guard onDisk.isEmpty else {
            // Its own chunk files — or another session's whose id starts with this one's (gotcha 85 (c)): kept either way.
            Logger.state.error("An ended session with no chunk in its state has \(onDisk.count, privacy: .public) file(s) named as its chunks on disk (its own, or a session whose id starts with its id) — its state is kept")
            return false
        }
        return SessionState.deleteIfEmpty(directory: outputDirectory, sessionId: sessionId)
    }

    /// Whether recovery has work to do. For a finalized session: its leftovers (session state, a
    /// missing TXT/SRT) when the transcript verifies — `cleanupFinalized` does it (round 4 item 1) —
    /// or, when the transcript can't be read back and its own session state is there, a rebuild
    /// (round 3 item 2).
    public static func isChunkedSessionRecoverable(outputDirectory: URL, sessionId: String) -> Bool {
        if isFinalized(outputDirectory: outputDirectory, sessionId: sessionId) {
            let transcript = outputDirectory.appendingPathComponent("\(sessionId).json")
            let state = SessionState.read(directory: outputDirectory, sessionId: sessionId)
            if TranscriptAssembler.verifies(transcript) {
                return state != nil || TranscriptWriter.formatFileIsMissing(forJSON: transcript)
            }
            return state.map { !$0.chunks.isEmpty } ?? false
        }
        let state = SessionState.read(directory: outputDirectory, sessionId: sessionId)
        if let state, !state.chunks.isEmpty { return true }
        let completed = Set(state?.chunks.map(\.index) ?? [])
        return !orphanChunks(outputDirectory: outputDirectory, sessionId: sessionId, completedIndices: completed).isEmpty
    }

    /// The next chunk index guaranteed not to collide with any chunk index already known to this
    /// session — either recorded as completed in `session.json` or present as a `<sessionId>-N.wav`
    /// or `.m4a` file on disk (C-M16: an index whose only artefact was its archive was reusable, and
    /// the archiver then removed that archive as stale output). Restart-capture sites (crash-relaunch,
    /// no-live-rotator XPC crash) must name their new WAV with this index, never with the legacy
    /// segment counter: the segment counter and the chunk-index namespace can collide, and colliding
    /// either drops the restart file as "already completed" or truncates an in-progress chunk's WAV
    /// on create (#135).
    public static func nextFreeChunkIndex(outputDirectory: URL, sessionId: String) -> Int {
        let completed = SessionState.read(directory: outputDirectory, sessionId: sessionId)?.chunks.map(\.index) ?? []
        let onDisk = onDiskChunkIndices(outputDirectory: outputDirectory, sessionId: sessionId).map(\.index)
        guard let maxIndex = (completed + onDisk).max() else { return 0 }
        return maxIndex + 1
    }

    /// The chunk index a restart-capture WAV must use so it never collides with any index this
    /// session already owns. Floors `nextFreeChunkIndex` at `sentinel.chunkIndex + 1` so a
    /// corrupt/unreadable `session.json` — which makes `nextFreeChunkIndex` under-report — can
    /// never hand back an index that drops the restart file as "already completed" or truncates
    /// the in-progress chunk's WAV on create (#135). This is the single collision guard shared by
    /// every restart site (crash-relaunch Flow B, XPC-crash restart, Flow A re-attach); call it,
    /// never re-derive the `max(nextFreeChunkIndex, chunkIndex + 1)` formula inline.
    ///
    /// `sentinel.systemAudioPath` must be the FULL absolute audio path (e.g.
    /// `.../m-3.wav`), not a bare session ID — this strips the segment suffix internally via
    /// `stripSegmentSuffix` (#158), so a caller that has already stripped it would double-strip.
    public static func safeRestartChunkIndex(sentinel: RecordingSentinel, outputDirectory: URL) -> Int {
        let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)
        return max(
            nextFreeChunkIndex(outputDirectory: outputDirectory, sessionId: sessionId),
            sentinel.chunkIndex + 1
        )
    }

    /// The full restart-naming plan for a "no live pipeline" restart: derive the collision-free
    /// base name for the new capture file and the sentinel to persist once capture is confirmed
    /// running. Shared by every restart that has no live pipeline — the crash-relaunch restart
    /// (Flow B), a Flow A re-attach's crash restart, and the XPC-crash restart when no live rotator
    /// exists (`RecordingCoordinator.handleXPCCrash`) — so a future fix to the naming sequence
    /// lands once instead of in each of them (#170). Not used by the LIVE-pipeline restart case
    /// (see `RecordingCoordinator.liveRestartPlan`), which derives its base name from the
    /// rotator's own recovery plan instead of a disk scan.
    public static func planRestart(
        sentinel: RecordingSentinel, outputDirectory: URL
    ) -> (baseName: String, newSentinel: RecordingSentinel) {
        // stripSegmentSuffix runs again inside safeRestartChunkIndex below on the same
        // sentinel.systemAudioPath — redundant work, not a bug. The two results feed different
        // things (sessionId here for baseName; the internal one for the disk scan), so there's no
        // clean way to share them without changing safeRestartChunkIndex's signature. Don't
        // "optimize" this by pre-stripping and passing the stripped id in — that's the real
        // double-strip safeRestartChunkIndex's doc comment warns about.
        let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)
        let idx = safeRestartChunkIndex(sentinel: sentinel, outputDirectory: outputDirectory)
        let baseName = "\(sessionId)-\(idx)"
        var newSentinel = sentinel.incrementedSegment(
            systemAudioPath: outputDirectory.appendingPathComponent(baseName + ".wav").path,
            micAudioPath: outputDirectory.appendingPathComponent(baseName + "_mic.wav").path
        )
        // Stamp the freshly computed index directly so the max(nextFreeChunkIndex,
        // chunkIndex+1) floor above stays tight even if a later disk scan fails (#154 finding 6).
        newSentinel.chunkIndex = idx
        return (baseName, newSentinel)
    }
}
