import Foundation
import os
import FluidAudio

/// Speaker diarization using FluidAudio's OfflineDiarizerManager.
/// Uses pyannote segmentation + WeSpeaker embeddings + VBx clustering.
/// Models must be pre-downloaded via preDownloadModels() during setup.
public actor FluidAudioDiarizer: DiarizationProvider {
    /// Keyed by effective forced speaker count; 0 = unforced (the hot path).
    private var managers: [Int: OfflineDiarizerManager] = [:]

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

    /// Exposed so a model-free unit test can assert the shipping default. The ground-truth AMI guard
    /// cannot run in CI (the fixture is git-ignored and the ML models are not downloaded there), so
    /// without this a revert to `false` would ship with the whole suite green — which is exactly how
    /// the original bug survived.
    public nonisolated var excludeOverlapSetting: Bool { excludeOverlap }

    /// The exact FluidAudio configuration this diarizer runs with — the single construction
    /// point, used by `ensureLoaded()` AND by the golden-config snapshot test. Public so the
    /// test snapshots the REAL config production builds, not a hand-rolled copy of it (a copy
    /// is how TranscriptMerger shipped six passing tests and zero production bytes). Any change
    /// to these values — ours or a FluidAudio default moving under a dependency bump — must
    /// show up as a red diff against the checked-in golden.
    /// - Parameter forcedSpeakerCount: the number of speakers the USER stated for this specific
    ///   recording. Overrides the diarizer's own `maxSpeakers`. Non-positive values are ignored —
    ///   "0 speakers" is not an answer, and pinning clustering to it would be worse than the
    ///   default. `nil` means "no answer given"; the configured/default behaviour applies.
    ///
    ///   `maxSpeakers` is a target rather than a ceiling in practice: on `150633-Paul feedback`
    ///   the unbounded default produced ONE speaker while `maxSpeakers` of 2/3/4 produced exactly
    ///   2/3/4. That is why a user's answer is routed here and not to a `numSpeakers` hint.
    public nonisolated func makeOfflineConfig(forcedSpeakerCount: Int? = nil) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig(embeddingExcludeOverlap: excludeOverlap)
        if let clusteringThreshold {
            config.clustering.threshold = clusteringThreshold
        }
        if let forced = forcedSpeakerCount, forced > 0 {
            config.clustering.maxSpeakers = forced
        } else if let maxSpeakers {
            config.clustering.maxSpeakers = maxSpeakers
        }
        return config
    }

    public init(clusteringThreshold: Double? = nil, maxSpeakers: Int? = nil, excludeOverlap: Bool = true) {
        self.clusteringThreshold = clusteringThreshold
        self.maxSpeakers = maxSpeakers
        self.excludeOverlap = excludeOverlap
    }

    /// - Parameter numSpeakers: the user's stated speaker count for this recording, or `nil`.
    ///   Until #67 this parameter was accepted and silently discarded — the body loaded one manager
    ///   and called `process` regardless — so every caller that passed a hint got the default
    ///   behaviour and no error. It is now routed to `clustering.maxSpeakers`.
    public func diarize(audioPath: URL, numSpeakers: Int?) async throws -> DiarizationResult {
        let startTime = ContinuousClock.now
        Logger.transcription.info("FluidAudio diarization starting: \(audioPath.lastPathComponent, privacy: .sensitive)")

        let mgr = try await ensureLoaded(forcedSpeakerCount: numSpeakers)
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

    /// `OfflineDiarizerManager` takes its config at init and exposes no per-call override, so a
    /// forced speaker count needs its own manager. Managers are cached per effective count: the
    /// unforced one is the hot path and is never rebuilt, and a re-diarization at a user-stated
    /// count pays one model load (from the local cache — no download) the first time that count
    /// is used.
    ///
    /// At most TWO managers are kept: the unforced one (key 0, the hot path, never evicted) and the
    /// most recent forced count. Keying without a bound let every distinct count accumulate its own
    /// manager, each holding the full pyannote + WeSpeaker + VBx models — capped at 21 only by the
    /// UI stepper's 1...20 range, which is not a property this actor should depend on. Re-detect is
    /// used a couple of times per session and never concurrently, so a one-deep forced slot costs
    /// nothing real and removes the growth entirely.
    private func ensureLoaded(forcedSpeakerCount: Int? = nil) async throws -> OfflineDiarizerManager {
        let key = forcedSpeakerCount.map { $0 > 0 ? $0 : 0 } ?? 0
        if let mgr = managers[key] {
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
        if !excludeOverlap {
            Logger.transcription.warning(
                "Diarization: excludeOverlap is FALSE — speaker embeddings will blend overlapping voices and are expected to collapse into a single speaker. Measured on a 4-speaker reference meeting: 1 speaker instead of 4. Remove diarization_exclude_overlap from config.json."
            )
        }
        let config = makeOfflineConfig(forcedSpeakerCount: forcedSpeakerCount)
        Logger.transcription.info(
            "Diarizer clustering: threshold=\(self.clusteringThreshold.map { String($0) } ?? "default", privacy: .public) maxSpeakers=\(config.clustering.maxSpeakers.map(String.init) ?? "default", privacy: .public) forcedByUser=\(key > 0 ? String(key) : "no", privacy: .public) excludeOverlap=\(self.excludeOverlap, privacy: .public)"
        )
        let mgr = OfflineDiarizerManager(config: config)
        try await mgr.prepareModels()

        let elapsed = ContinuousClock.now - loadStart
        Logger.transcription.info("FluidAudio diarization models loaded in \(elapsed.components.seconds)s")

        // Actors re-enter at every `await`, and `prepareModels()` above is one. Two callers that
        // both missed the cache before it will both arrive here having loaded the full model stack;
        // without this re-check each would then evict the other's entry below. Keep whichever
        // landed first so concurrent callers converge on one manager instead of thrashing.
        if let existing = managers[key] {
            return existing
        }

        // Evict any previously cached forced count; keep key 0 (unforced) permanently.
        managers = managers.filter { $0.key == 0 }
        managers[key] = mgr
        return mgr
    }
}
