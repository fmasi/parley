import Foundation
import os

/// Rehydrate a chunked recording session after a crash: read `session.json` — or the session's
/// moved-aside `session-<id>.json` (C-I3) — or start from an empty state, re-ingest any orphan chunk
/// (a WAV, or an archive whose WAVs are gone) still on disk that never made it into `session.json`,
/// then finalize — producing the same offset-aware, cross-chunk-reconciled
/// transcript a clean stop would have produced.
@MainActor
public enum ChunkedSessionRecovery {
    public static func recover(outputDirectory: URL, sessionId: String, config: Config,
                        transcriber: any TranscriptionEngine, diarizer: (any DiarizationProvider)?,
                        runner: TranscriptionRunner, provenance: CaptureProvenance? = nil) async throws -> TranscriptionResult? {
        // A finalized session is finished (R2a item 12): a lingering recovery file never re-ingests its
        // chunks (preserved WAVs, archives) or re-finalizes over its transcript — renames and edits
        // would be lost.
        if CrashRecoveryPlanner.isFinalized(outputDirectory: outputDirectory, sessionId: sessionId) {
            let transcript = outputDirectory.appendingPathComponent("\(sessionId).json")
            if TranscriptAssembler.verifies(transcript) {
                // Verified: a leftover session.json (a crash between the marker and its deletion) goes,
                // so the next recording records no false displacement, and a missing TXT/SRT is
                // re-written from the transcript (round 3 items 2, 3).
                Logger.state.info("Recovery found \(sessionId, privacy: .sensitive) already finalized — the recovery file lingered; nothing re-ingested or re-finalized")
                SessionState.delete(directory: outputDirectory, sessionId: sessionId)
                rewriteMissingFormatFile(of: transcript)
                return TranscriptionResult(jsonPath: transcript)
            }
            // The transcript is missing or unreadable. Never delete session.json on the marker's word:
            // when this session's state is there, finalize again from it — its chunks only, no orphans.
            guard var state = SessionState.read(directory: outputDirectory, sessionId: sessionId), !state.chunks.isEmpty else {
                Logger.state.info("Recovery found \(sessionId, privacy: .sensitive) finalized, its transcript gone or unreadable and no session state — nothing re-ingested")
                return nil
            }
            Logger.state.error("Recovery found \(sessionId, privacy: .sensitive) finalized but its transcript unreadable — finalizing again from session.json")
            if let provenance { state.provenance = provenance }
            return try await runner.finalize(sessionState: state, outputDirectory: outputDirectory, config: config)
        }
        let existingState = SessionState.read(directory: outputDirectory, sessionId: sessionId)
        // `orphanChunks` only needs completed indices, not the whole baseState, so it's computed
        // before baseState — the all-orphan fallback below needs the orphan list to derive
        // meetingStart.
        let orphans = CrashRecoveryPlanner.orphanChunks(
            outputDirectory: outputDirectory, sessionId: sessionId,
            completedIndices: Set(existingState?.chunks.map(\.index) ?? [])
        )
        let baseState = existingState ?? {
            // No session.json at all — every chunk is an orphan. Derive meetingStart from the
            // earliest orphan WAV's filesystem creation date rather than defaulting to `Date()`
            // (recovery time), which would stamp the transcript with a start time that's
            // potentially much later than when the meeting actually began.
            let earliestOrphanCreation = orphans.compactMap { estimatedStart(of: $0, in: outputDirectory) }.min()
            return SessionState(sessionId: sessionId, meetingStart: earliestOrphanCreation ?? Date(),
                                engine: config.engine.rawValue,
                                chunkDurationMinutes: config.validatedChunkDuration, chunks: [])
        }()
        guard !baseState.chunks.isEmpty || !orphans.isEmpty else { return nil }
        let processor = ChunkProcessor(config: config, outputDirectory: outputDirectory,
                                       sessionState: baseState, transcriber: transcriber, diarizer: diarizer)
        for orphan in orphans {
            let sysURL = outputDirectory.appendingPathComponent(orphan.baseName + ".wav")
            let start = estimatedStart(of: orphan, in: outputDirectory)
                ?? baseState.meetingStart.addingTimeInterval(Double(orphan.index) * Double(baseState.chunkDurationMinutes) * 60)
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
            // ChunkProcessor's write/append coupling ever changes.
            SessionState.delete(directory: outputDirectory, sessionId: sessionId)
            return nil
        }
        if let provenance { state.provenance = provenance }
        return try await runner.finalize(sessionState: state, outputDirectory: outputDirectory, config: config)
    }

    /// The TXT/SRT a finalized transcript's `output_format` asks for, re-written when missing.
    private static func rewriteMissingFormatFile(of transcript: URL) {
        guard let data = try? Data(contentsOf: transcript),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = (json["metadata"] as? [String: Any])?["output_format"] as? String,
              ["txt", "srt"].contains(format)
        else { return }
        let file = transcript.deletingPathExtension().appendingPathExtension(format)
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try TranscriptWriter.writeFormatFile(fromJSON: transcript)
        } catch {
            Logger.files.error("Could not re-write the finalized transcript's \(format, privacy: .public): \(error, privacy: .private)")
        }
    }

    /// When an orphan chunk began: its WAV's creation date (the helper created it at the rotation).
    /// An orphan left only as its archive (C-I4) was written after the chunk ended, so its start is
    /// the archive's creation date minus its length — an estimate, a few seconds late.
    static func estimatedStart(of orphan: CrashRecoveryPlanner.OrphanChunk, in directory: URL) -> Date? {
        let wav = directory.appendingPathComponent(orphan.baseName + ".wav")
        if let created = try? wav.resourceValues(forKeys: [.creationDateKey]).creationDate { return created }
        let archive = directory.appendingPathComponent(orphan.baseName + ".m4a")
        guard let created = try? archive.resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
        return created.addingTimeInterval(-TranscriptAssembler.duration(of: archive))
    }
}
