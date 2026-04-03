import Foundation
import os
import FluidAudio

/// Speaker diarization using FluidAudio's OfflineDiarizerManager.
/// Uses pyannote segmentation + WeSpeaker embeddings + VBx clustering.
/// Models must be pre-downloaded via preDownloadModels() during setup.
public actor FluidAudioDiarizer: DiarizationProvider {
    private var manager: OfflineDiarizerManager?

    public init() {}

    public func diarize(audioPath: URL, numSpeakers: Int?) async throws -> [DiarizedSegment] {
        let startTime = ContinuousClock.now
        Logger.transcription.info("FluidAudio diarization starting: \(audioPath.lastPathComponent, privacy: .public)")

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

        let elapsed = ContinuousClock.now - startTime
        let speakerCount = Set(segments.map(\.speaker)).count
        Logger.transcription.info(
            "FluidAudio diarization complete: \(segments.count) segments, \(speakerCount) speakers in \(elapsed.components.seconds)s"
        )

        return segments
    }

    /// Returns true if all diarization model files are present in the local cache.
    public static func isDiarizationCached() -> Bool {
        let baseDir = OfflineDiarizerModels.defaultModelsDirectory()
        let repoDir = baseDir.appendingPathComponent(Repo.diarizer.folderName)
        let fm = FileManager.default
        return ModelNames.OfflineDiarizer.requiredModels.allSatisfy {
            fm.fileExists(atPath: repoDir.appendingPathComponent($0).path)
        }
    }

    /// Download diarization models to the local cache without keeping them in memory.
    /// Safe to call if already cached — OfflineDiarizerManager skips re-download.
    public static func preDownloadModels(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let mgr = OfflineDiarizerManager()
        try await mgr.prepareModels()
        // Manager and loaded models are discarded — just ensures files are on disk
        Logger.transcription.info("FluidAudio diarization model pre-download complete")
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

        let config = OfflineDiarizerConfig(embeddingExcludeOverlap: false)
        let mgr = OfflineDiarizerManager(config: config)
        try await mgr.prepareModels()

        let elapsed = ContinuousClock.now - loadStart
        Logger.transcription.info("FluidAudio diarization models loaded in \(elapsed.components.seconds)s")

        manager = mgr
        return mgr
    }
}
