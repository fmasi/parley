import Foundation
import os
import FluidAudio

/// Speaker diarization using FluidAudio's OfflineDiarizerManager.
/// Uses pyannote segmentation + WeSpeaker embeddings + VBx clustering.
/// Models download automatically on first use (~10MB).
public final class FluidAudioDiarizer: DiarizationProvider, @unchecked Sendable {
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
                speaker: seg.speakerId
            )
        }

        let elapsed = ContinuousClock.now - startTime
        let speakerCount = Set(segments.map(\.speaker)).count
        Logger.transcription.info(
            "FluidAudio diarization complete: \(segments.count) segments, \(speakerCount) speakers in \(elapsed.components.seconds)s"
        )

        return segments
    }

    private func ensureLoaded() async throws -> OfflineDiarizerManager {
        if let mgr = manager {
            return mgr
        }

        let loadStart = ContinuousClock.now
        Logger.transcription.info("Loading FluidAudio diarization models...")

        let mgr = OfflineDiarizerManager()
        try await mgr.prepareModels()

        let elapsed = ContinuousClock.now - loadStart
        Logger.transcription.info("FluidAudio diarization models loaded in \(elapsed.components.seconds)s")

        manager = mgr
        return mgr
    }
}
