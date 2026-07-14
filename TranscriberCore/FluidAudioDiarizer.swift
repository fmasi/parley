import Foundation
import os
import FluidAudio

/// Speaker diarization using FluidAudio's OfflineDiarizerManager.
/// Uses pyannote segmentation + WeSpeaker embeddings + VBx clustering.
/// Models must be pre-downloaded via preDownloadModels() during setup.
public actor FluidAudioDiarizer: DiarizationProvider {
    private var manager: OfflineDiarizerManager?

    /// Euclidean distance threshold for unit-normalized embeddings. LOWER = stricter = more
    /// speakers kept apart; HIGHER = more merging. nil uses FluidAudio's default (0.6).
    ///
    /// Exposed because the default under-clusters real conference calls: on a 5-speaker call
    /// over compressed Meet audio, one cluster absorbed 28.7 of 51 minutes and a participant
    /// who genuinely spoke got no cluster at all.
    private let clusteringThreshold: Double?
    /// Upper bound on speakers. Helps VBx when the true count is known.
    private let maxSpeakers: Int?

    /// Whether to EXCLUDE overlapped speech when computing speaker embeddings.
    ///
    /// MUST default to true (FluidAudio's own default). Setting it false was catastrophic: an
    /// embedding computed over a window containing two voices is a blend of both, so with overlap
    /// included EVERY embedding converges and the clusterer sees a single speaker.
    ///
    /// Measured on AMI ES2004a (a 4-speaker reference meeting, clean audio):
    ///   excludeOverlap = false -> 1 speaker  (639 of 642 embeddings in one cluster)
    ///   excludeOverlap = true  -> 4 speakers (correct; healthy cluster sizes 226/170/91/51)
    private let excludeOverlap: Bool

    public init(clusteringThreshold: Double? = nil, maxSpeakers: Int? = nil, excludeOverlap: Bool = true) {
        self.clusteringThreshold = clusteringThreshold
        self.maxSpeakers = maxSpeakers
        self.excludeOverlap = excludeOverlap
    }

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

        // Exclude overlapped speech from embeddings (FluidAudio's default). The previous code
        // forced this to false, on the theory that on a mixed mono stream "all remote speech is
        // technically overlapping" so the mask would discard most embeddings. That reasoning is
        // wrong -- the mask marks frames where two SPEAKERS overlap, not merely remote speech --
        // and the override caused exactly the collapse it was meant to avoid (see excludeOverlap).
        var config = OfflineDiarizerConfig(embeddingExcludeOverlap: excludeOverlap)
        if let clusteringThreshold {
            config.clustering.threshold = clusteringThreshold
        }
        if let maxSpeakers {
            config.clustering.maxSpeakers = maxSpeakers
        }
        Logger.transcription.info(
            "Diarizer clustering: threshold=\(self.clusteringThreshold.map { String($0) } ?? "default", privacy: .public) maxSpeakers=\(self.maxSpeakers.map(String.init) ?? "unset", privacy: .public) excludeOverlap=\(self.excludeOverlap, privacy: .public)"
        )
        let mgr = OfflineDiarizerManager(config: config)
        try await mgr.prepareModels()

        let elapsed = ContinuousClock.now - loadStart
        Logger.transcription.info("FluidAudio diarization models loaded in \(elapsed.components.seconds)s")

        manager = mgr
        return mgr
    }
}
