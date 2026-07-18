import Foundation

/// Rehydrate a chunked recording session after a crash: read `session.json` (or start from an
/// empty state), re-ingest any orphan chunk WAVs still on disk that never made it into
/// `session.json`, then finalize — producing the same offset-aware, cross-chunk-reconciled
/// transcript a clean stop would have produced.
@MainActor
public enum ChunkedSessionRecovery {
    public static func recover(outputDirectory: URL, sessionId: String, config: Config,
                        transcriber: any TranscriptionEngine, diarizer: (any DiarizationProvider)?,
                        runner: TranscriptionRunner, provenance: CaptureProvenance? = nil) async throws -> TranscriptionResult? {
        let existingState = SessionState.read(directory: outputDirectory)
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
            let earliestOrphanCreation = orphans.compactMap {
                try? outputDirectory.appendingPathComponent($0.baseName + ".wav")
                    .resourceValues(forKeys: [.creationDateKey]).creationDate
            }.min()
            return SessionState(sessionId: sessionId, meetingStart: earliestOrphanCreation ?? Date(),
                                engine: config.engine.rawValue,
                                chunkDurationMinutes: config.validatedChunkDuration, chunks: [])
        }()
        guard !baseState.chunks.isEmpty || !orphans.isEmpty else { return nil }
        let processor = ChunkProcessor(config: config, outputDirectory: outputDirectory,
                                       sessionState: baseState, transcriber: transcriber, diarizer: diarizer)
        for orphan in orphans {
            let sysURL = outputDirectory.appendingPathComponent(orphan.baseName + ".wav")
            let start = (try? sysURL.resourceValues(forKeys: [.creationDateKey]).creationDate)
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
        // Defensive no-op on this sequential path: `processLastChunk` above is awaited inline per
        // orphan, and `inFlightTasks` is only ever populated by the fire-and-forget `processChunk`
        // (used by the live rotation path, not recovery). Kept as belt-and-suspenders in case this
        // method's contract changes to enqueue background work.
        await processor.awaitAllProcessed()
        var state = await processor.getSessionState()
        guard !state.chunks.isEmpty else { return nil }
        if let provenance { state.provenance = provenance }
        return try await runner.finalize(sessionState: state, outputDirectory: outputDirectory, config: config)
    }
}
