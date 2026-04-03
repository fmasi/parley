import Foundation
import os
import FluidAudio

/// Time-indexed speech probability from Silero VAD.
/// Used as a parallel quality signal in SpeakerAssignment.
public struct SpeechRegion: Sendable {
    public let start: Double
    public let end: Double
    public let probability: Float

    public init(start: Double, end: Double, probability: Float) {
        self.start = start
        self.end = end
        self.probability = probability
    }

    /// Calculate what fraction of [start, end] overlaps with speech regions
    /// whose probability meets the threshold.
    /// Returns 0.0–1.0.
    public static func speechOverlap(
        regions: [SpeechRegion],
        start: Double,
        end: Double,
        threshold: Float
    ) -> Double {
        let duration = end - start
        guard duration > 0 else { return 0.0 }

        var overlap = 0.0
        for region in regions {
            guard region.probability >= threshold else { continue }
            let overlapStart = max(start, region.start)
            let overlapEnd = min(end, region.end)
            let regionOverlap = max(0, overlapEnd - overlapStart)
            overlap += regionOverlap
        }

        return min(1.0, overlap / duration)
    }
}

/// Wraps FluidAudio's VadManager to produce a speech map for quality filtering.
/// Runs concurrently with diarization — near-zero added latency (RTFx ~100x).
public actor VadSpeechMap {
    private var manager: VadManager?

    public init() {}

    /// Analyze audio and return speech regions with probabilities.
    /// Returns nil if VAD model is not cached (graceful degradation).
    public func analyze(audioPath: URL) async throws -> [SpeechRegion]? {
        guard Self.isModelCached() else {
            Logger.transcription.debug("VAD model not cached — skipping speech map analysis")
            return nil
        }

        let startTime = ContinuousClock.now
        let mgr = try await ensureLoaded()

        let results = try await mgr.process(audioPath)

        let chunkDuration = Double(VadManager.chunkSize) / Double(VadManager.sampleRate)
        let regions = results.enumerated().map { (index, result) in
            SpeechRegion(
                start: Double(index) * chunkDuration,
                end: Double(index + 1) * chunkDuration,
                probability: result.probability
            )
        }

        let elapsed = ContinuousClock.now - startTime
        let speechCount = regions.filter { $0.probability >= 0.5 }.count
        let speechRatio = regions.isEmpty ? 0.0 : Double(speechCount) / Double(regions.count)
        Logger.transcription.info(
            "VAD analysis: \(regions.count) chunks, \(String(format: "%.0f", speechRatio * 100))% speech in \(elapsed.components.seconds)s"
        )

        return regions
    }

    /// Check if the Silero VAD model is present in the local cache.
    public nonisolated static func isModelCached() -> Bool {
        let baseDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("FluidAudio", isDirectory: true)
        let modelsDir = baseDir.appendingPathComponent("Models")
        let vadDir = modelsDir.appendingPathComponent(Repo.vad.folderName)
        return ModelNames.VAD.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: vadDir.appendingPathComponent($0).path)
        }
    }

    /// Download the Silero VAD model to the local cache.
    /// Safe to call if already cached.
    public static func preDownloadModel() async throws {
        let _ = try await VadManager()
        Logger.transcription.info("VAD model pre-download complete")
    }

    private func ensureLoaded() async throws -> VadManager {
        if let mgr = manager {
            return mgr
        }

        let loadStart = ContinuousClock.now
        Logger.transcription.info("Loading Silero VAD model from cache...")

        let mgr = try await VadManager()

        let elapsed = ContinuousClock.now - loadStart
        Logger.transcription.info("VAD model loaded in \(elapsed.components.seconds)s")

        manager = mgr
        return mgr
    }
}
