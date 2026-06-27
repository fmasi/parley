import Foundation
import os
import FluidAudio

/// Speaker diarization using FluidAudio's OfflineDiarizerManager.
/// Uses pyannote segmentation + WeSpeaker embeddings + VBx clustering.
/// Models must be pre-downloaded via preDownloadModels() during setup.
public actor FluidAudioDiarizer: DiarizationProvider {
    private var manager: OfflineDiarizerManager?

    public init() {}

    public func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult {
        let startTime = ContinuousClock.now
        Logger.transcription.info("FluidAudio diarization starting: \(audioPath.lastPathComponent, privacy: .private)")

        let mgr = try await ensureLoaded()
        let result = try await mgr.process(audioPath)

        let segments = result.segments.map { seg in
            DiarizedSegment(
                start: Double(seg.startTimeSeconds),
                end: Double(seg.endTimeSeconds),
                speaker: seg.speakerId,
                qualityScore: seg.qualityScore
            )
        }

        let speakerDatabase = result.speakerDatabase ?? [:]

        let elapsed = ContinuousClock.now - startTime
        let speakerCount = Set(segments.map(\.speaker)).count
        Logger.transcription.info(
            "FluidAudio diarization complete: \(segments.count) segments, \(speakerCount) speakers in \(elapsed.components.seconds)s"
        )

        return DiarizationResult(segments: segments, speakerDatabase: speakerDatabase)
    }

    /// Returns true if all diarization model files are present in the local cache.
    /// Used by ensureLoaded() — does NOT require VAD so existing installs keep working.
    public static func isDiarizationCached() -> Bool {
        let baseDir = OfflineDiarizerModels.defaultModelsDirectory()
        let repoDir = baseDir.appendingPathComponent(Repo.diarizer.folderName)
        let fm = FileManager.default
        // Check directory existence first — primes the VFS metadata cache so
        // subsequent child-path checks reflect the current on-disk state.
        guard fm.fileExists(atPath: repoDir.path) else { return false }
        return ModelNames.OfflineDiarizer.requiredModels.allSatisfy {
            fm.fileExists(atPath: repoDir.appendingPathComponent($0).path)
        }
    }

    /// Returns true if ALL models (diarization + VAD) are present.
    /// Used by Setup/Settings UI to gate "ready" state — ensures full capability after setup.
    public static func isFullyReady() -> Bool {
        isDiarizationCached() && VadSpeechMap.isModelCached()
    }

    /// Download diarization + VAD models to the local cache without keeping them in memory.
    /// Safe to call if already cached — managers skip re-download.
    public static func preDownloadModels(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let mgr = OfflineDiarizerManager()
        try await mgr.prepareModels()
        Logger.transcription.info("FluidAudio diarization model pre-download complete")

        try await VadSpeechMap.preDownloadModel()
    }

    private func ensureLoaded() async throws -> OfflineDiarizerManager {
        if let mgr = manager {
            return mgr
        }

        guard Self.isDiarizationCached() else {
            Logger.transcription.error("Diarization models not cached — download from Settings first")
            throw FluidAudioEngineError.modelNotDownloaded
        }

        let loadStart = ContinuousClock.now
        Logger.transcription.info("Loading FluidAudio diarization models from cache...")

        // false = include overlap embeddings. On mixed mono streams (Zoom/Teams system audio)
        // all remote speech is technically "overlapping", so the default true masks most embeddings
        // and collapses remote speakers into one cluster.
        let config = OfflineDiarizerConfig(embeddingExcludeOverlap: false)
        let mgr = OfflineDiarizerManager(config: config)
        try await mgr.prepareModels()

        let elapsed = ContinuousClock.now - loadStart
        Logger.transcription.info("FluidAudio diarization models loaded in \(elapsed.components.seconds)s")

        manager = mgr
        return mgr
    }
}
