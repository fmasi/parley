import Foundation

/// Rehydrate a chunked recording session after a crash: read `session.json` (or start from an
/// empty state), re-ingest any orphan chunk WAVs still on disk that never made it into
/// `session.json`, then finalize — producing the same offset-aware, cross-chunk-reconciled
/// transcript a clean stop would have produced.
@MainActor
public enum ChunkedSessionRecovery {
    public static func recover(outputDirectory: URL, sessionId: String, config: Config,
                        transcriber: any TranscriptionEngine, diarizer: (any DiarizationProvider)?,
                        runner: TranscriptionRunner) async throws -> TranscriptionResult? {
        let baseState = SessionState.read(directory: outputDirectory)
            ?? SessionState(sessionId: sessionId, meetingStart: Date(), engine: config.engine.rawValue,
                            chunkDurationMinutes: config.validatedChunkDuration, chunks: [])
        let completed = Set(baseState.chunks.map(\.index))
        let orphans = CrashRecoveryPlanner.orphanChunks(outputDirectory: outputDirectory, sessionId: sessionId, completedIndices: completed)
        guard !baseState.chunks.isEmpty || !orphans.isEmpty else { return nil }
        let processor = ChunkProcessor(config: config, outputDirectory: outputDirectory,
                                       sessionState: baseState, transcriber: transcriber, diarizer: diarizer)
        for orphan in orphans {
            let sysURL = outputDirectory.appendingPathComponent(orphan.baseName + ".wav")
            let start = (try? sysURL.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? baseState.meetingStart.addingTimeInterval(Double(orphan.index) * Double(baseState.chunkDurationMinutes) * 60)
            let micURL = outputDirectory.appendingPathComponent(orphan.baseName + "_mic.wav")
            let hasMic = FileManager.default.fileExists(atPath: micURL.path)
            await processor.processLastChunk(ChunkRotator.FinalizedChunk(
                index: orphan.index, systemPath: sysURL.path,
                micPath: hasMic ? micURL.path : sysURL.path, startTime: start))
        }
        await processor.awaitAllProcessed()
        let state = await processor.getSessionState()
        guard !state.chunks.isEmpty else { return nil }
        return try await runner.finalize(sessionState: state, outputDirectory: outputDirectory, config: config)
    }
}
