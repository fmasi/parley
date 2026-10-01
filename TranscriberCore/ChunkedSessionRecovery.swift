import Foundation
import os

/// Rehydrate a chunked recording session after a crash: read `session.json` — or the session's
/// moved-aside `session-<id>.json` (C-I3) — or start from an empty state, re-ingest any orphan chunk
/// (a WAV, or an archive whose WAVs are gone) still on disk that never made it into `session.json`,
/// then finalize — producing the same offset-aware, cross-chunk-reconciled
/// transcript a clean stop would have produced.
@MainActor
public enum ChunkedSessionRecovery {
    /// What the look at the folder found (L review 158): read off the main actor, bounded.
    enum Preparation {
        /// Finalized, its transcript verifies: the leftovers are cleaned up, the transcript handed back as it is.
        case alreadyFinalized(URL)
        /// Nothing to re-ingest or rebuild.
        case nothing
        /// The chunks to process, each with its estimated start, on top of `baseState`.
        case process(baseState: SessionState, orphans: [(chunk: CrashRecoveryPlanner.OrphanChunk, start: Date)], rebuilding: Bool)
    }

    /// The recovery's reads of the folder run through `reads`, bounded by `seconds` of awake time, never on the main actor
    /// (L review 158): a folder that does not answer throws `FolderNotAnswering` — nothing is transcribed, nothing lost. The
    /// composite `prepare` — sweeps, a move aside, the state and orphan reads — gets its own, longer bound, `prepareSeconds`
    /// (L review 215).
    public static func recover(outputDirectory: URL, sessionId: String, config: Config,
                        transcriber: any TranscriptionEngine, diarizer: (any DiarizationProvider)?,
                        runner: TranscriptionRunner, provenance: CaptureProvenance? = nil,
                        reads: FolderReads = .shared, seconds: Double = 15, prepareSeconds: Double = 15) async throws -> TranscriptionResult? {
        let engine = config.engine.rawValue, chunkMinutes = config.validatedChunkDuration
        guard let prepared = await reads.read("recovery: session folder", folder: outputDirectory.path,
                                              key: outputDirectory.path + "#recovery:" + sessionId, seconds: prepareSeconds, {
            Result { try prepare(outputDirectory: outputDirectory, sessionId: sessionId, engine: engine, chunkMinutes: chunkMinutes) }
        }) else { throw FolderNotAnswering() }
        let (baseState, orphans, rebuilding): (SessionState, [(chunk: CrashRecoveryPlanner.OrphanChunk, start: Date)], Bool)
        switch try prepared.get() {
        case .alreadyFinalized(let transcript): return TranscriptionResult(jsonPath: transcript)
        case .nothing: return nil
        case .process(let state, let found, let rebuild): (baseState, orphans, rebuilding) = (state, found, rebuild)
        }
        // Its session.json writes on the folder's queue, within the transcript's write bound (L review 234).
        let processor = ChunkProcessor(config: config, outputDirectory: outputDirectory,
                                       sessionState: baseState, transcriber: transcriber, diarizer: diarizer,
                                       folderReads: reads, writeSeconds: runner.folderWriteSeconds)
        for (orphan, start) in orphans {
            let sysURL = outputDirectory.appendingPathComponent(orphan.baseName + ".wav")
            let micURL = outputDirectory.appendingPathComponent(orphan.baseName + "_mic.wav")
            // Always pass the real mic path, even when it doesn't exist. `ChunkProcessor` decides
            // dual-stream via `FileManager.fileExists(atPath: chunk.micPath)` — pointing micPath at
            // the system WAV instead (as this used to do) makes that check lie for a system-only
            // orphan, misclassifying it as dual-stream and transcribing its system audio a second
            // time as the "local" channel (#135).
            await processor.processLastChunk(ChunkRotator.FinalizedChunk(
                index: orphan.index, systemPath: sysURL.path,
                micPath: micURL.path, startTime: start))
        }
        // Defensive on this sequential path: `processLastChunk` above already awaits each orphan's
        // task. `awaitAllProcessed` awaits every task the processor scheduled, so it also covers any
        // background work a future change to this method might enqueue.
        await processor.awaitAllProcessed()
        var state = await processor.getSessionState()
        guard !state.chunks.isEmpty else {
            // Reachable if every orphan WAV produced no usable chunk. Not data-loss — the caller
            // deletes the sentinel regardless, so recovery is never re-attempted — but without
            // this, a stale session.json lingers on disk forever (#158).
            //
            // Safe only under the invariant that processLastChunk writes session.json to disk
            // if and only if it appends to state.chunks. If a future change adds an error path
            // that writes session.json (e.g. a partial flush) without appending, this delete
            // would silently erase data that was just persisted — check this guard first if
            // ChunkProcessor's write/append coupling ever changes. Off the main actor, bounded.
            _ = await reads.read("recovery: progress file", folder: outputDirectory.path, key: outputDirectory.path + "#recovery-delete:" + sessionId,
                                 seconds: seconds) { SessionState.delete(directory: outputDirectory, sessionId: sessionId) }
            return nil
        }
        // A rebuild's capture facts are the relaunch's, not the recording's: said so (round 4 item 7).
        if let provenance { state.provenance = rebuilding ? provenance.markedReconstructed() : provenance }
        return try await runner.finalize(sessionState: state, outputDirectory: outputDirectory, config: config)
    }

    /// Everything the recovery reads — and the leftovers it cleans up, the damaged record it moves aside — before it
    /// processes a chunk: blocking file-system work, run only through `reads`.
    nonisolated static func prepare(outputDirectory: URL, sessionId: String, engine: String, chunkMinutes: Int) throws -> Preparation {
        SessionState.sweepTemporaries(directory: outputDirectory, sessionId: sessionId)
        // A finalized session is finished (R2a item 12): a lingering recovery file never re-ingests its
        // chunks (preserved WAVs, archives) or re-finalizes over its transcript — renames and edits
        // would be lost.
        var rebuilding = false
        if CrashRecoveryPlanner.isFinalized(outputDirectory: outputDirectory, sessionId: sessionId) {
            let transcript = outputDirectory.appendingPathComponent("\(sessionId).json")
            if CrashRecoveryPlanner.cleanupFinalized(outputDirectory: outputDirectory, sessionId: sessionId) {
                // Verified: its leftovers are cleaned up and its transcript handed back as it is.
                Logger.state.info("Recovery found \(sessionId, privacy: .sensitive) already finalized — the recovery file lingered; nothing re-ingested or re-finalized")
                return .alreadyFinalized(transcript)
            }
            // The transcript is missing or unreadable. Never delete session.json on the marker's word:
            // when this session's state is there, rebuild from it (plus any unregistered chunk).
            guard let state = SessionState.read(directory: outputDirectory, sessionId: sessionId), !state.chunks.isEmpty else {
                Logger.state.info("Recovery found \(sessionId, privacy: .sensitive) finalized, its transcript gone or unreadable and no session state — nothing re-ingested")
                return .nothing
            }
            Logger.state.error("Recovery found \(sessionId, privacy: .sensitive) finalized but its transcript unreadable (\(state.chunks.count, privacy: .public) chunks) — rebuilding it")
            try moveDamagedRecordAside(transcript)
            rebuilding = true
        }
        let existingState = SessionState.read(directory: outputDirectory, sessionId: sessionId)
        // `orphanChunks` only needs completed indices, not the whole baseState, so it's computed
        // before baseState — the all-orphan fallback below needs the orphan list to derive
        // meetingStart. A rebuild takes unregistered chunks too — a failed session.json write left
        // them out (round 4 item 3); the finalized guard would hide them.
        let completed = Set(existingState?.chunks.map(\.index) ?? [])
        let orphans = rebuilding
            ? CrashRecoveryPlanner.unregisteredChunks(outputDirectory: outputDirectory, sessionId: sessionId, completedIndices: completed)
            : CrashRecoveryPlanner.orphanChunks(outputDirectory: outputDirectory, sessionId: sessionId, completedIndices: completed)
        let baseState = existingState ?? {
            // No session.json at all — every chunk is an orphan. Derive meetingStart from the
            // earliest orphan WAV's filesystem creation date rather than defaulting to `Date()`
            // (recovery time), which would stamp the transcript with a start time that's
            // potentially much later than when the meeting actually began.
            let earliestOrphanCreation = orphans.compactMap { estimatedStart(of: $0, in: outputDirectory) }.min()
            return SessionState(sessionId: sessionId, meetingStart: earliestOrphanCreation ?? Date(),
                                engine: engine, chunkDurationMinutes: chunkMinutes, chunks: [])
        }()
        guard !baseState.chunks.isEmpty || !orphans.isEmpty else { return .nothing }
        let starts = orphans.map { orphan in
            estimatedStart(of: orphan, in: outputDirectory)
                ?? baseState.meetingStart.addingTimeInterval(Double(orphan.index) * Double(baseState.chunkDurationMinutes) * 60)
        }
        return .process(baseState: baseState, orphans: Array(zip(orphans, starts)).map { ($0.0, $0.1) }, rebuilding: rebuilding)
    }

    /// The damaged record is kept, never overwritten by its rebuild (round 4 item 2, round 6 item 2):
    /// the transcript and its companions — the TXT/SRT and the summary, possibly the only readable
    /// copies, renames included, and the re-detect backup — move to `<id>.damaged.json`,
    /// `<id>.damaged.txt`, `<id>.damaged.srt`, `<id>-summary.damaged.md` and `<id>.damaged.json.bak`
    /// (a unique suffix when a name is taken).
    nonisolated private static func moveDamagedRecordAside(_ transcript: URL) throws {
        let base = transcript.deletingPathExtension().lastPathComponent
        let directory = transcript.deletingLastPathComponent()
        // …and the re-detect backup `<id>.json.bak`, so the rebuilt record's first re-detect writes
        // its own (round 7 item 4).
        let companions = [("\(base).json", "\(base).damaged", "json"), ("\(base).txt", "\(base).damaged", "txt"),
                          ("\(base).srt", "\(base).damaged", "srt"), ("\(base)-summary.md", "\(base)-summary.damaged", "md"),
                          ("\(base).json.bak", "\(base).damaged", "json.bak")]
        for (name, asideBase, ext) in companions {
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var aside = directory.appendingPathComponent("\(asideBase).\(ext)")
            if FileManager.default.fileExists(atPath: aside.path) {
                aside = directory.appendingPathComponent("\(asideBase)-\(UUID().uuidString).\(ext)")
            }
            try FileManager.default.moveItem(at: file, to: aside)
            Logger.state.error("Kept the damaged record's \(ext, privacy: .public) as \(aside.lastPathComponent, privacy: .sensitive)")
        }
    }

    /// When an orphan chunk began: its WAV's creation date (the helper created it at the rotation).
    /// An orphan left only as its archive (C-I4) was written after the chunk ended, so its start is
    /// the archive's creation date minus its length — an estimate, a few seconds late.
    nonisolated static func estimatedStart(of orphan: CrashRecoveryPlanner.OrphanChunk, in directory: URL) -> Date? {
        let wav = directory.appendingPathComponent(orphan.baseName + ".wav")
        if let created = try? wav.resourceValues(forKeys: [.creationDateKey]).creationDate { return created }
        let archive = directory.appendingPathComponent(orphan.baseName + ".m4a")
        guard let created = try? archive.resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
        return created.addingTimeInterval(-TranscriptAssembler.duration(of: archive))
    }
}
