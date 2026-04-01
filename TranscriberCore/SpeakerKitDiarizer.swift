import Foundation
import os
import WhisperKit
import SpeakerKit

/// Native Swift diarization using SpeakerKit (Pyannote CoreML backend).
///
/// Models are downloaded on first use from argmaxinc/speakerkit-coreml
/// and loaded lazily before each diarization run.
public final class NativeSpeakerKitDiarizer: DiarizationProvider, @unchecked Sendable {

    public init() {}

    public func diarize(audioPath: URL, numSpeakers: Int?) async throws -> [DiarizedSegment] {
        let startTime = ContinuousClock.now
        Logger.transcription.info("SpeakerKit diarization starting: \(audioPath.lastPathComponent, privacy: .public)")

        // Load audio as 16 kHz mono Float array (SpeakerKit requirement).
        Logger.transcription.debug("SpeakerKit: loading audio from disk")
        let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath.path)
        Logger.transcription.debug("SpeakerKit: loaded \(audioArray.count) samples (\(String(format: "%.1f", Double(audioArray.count) / 16000.0))s)")

        // Initialise SpeakerKit. download=true ensures models are fetched if absent;
        // load=false defers model load to ensureModelsLoaded() inside diarize().
        let config = PyannoteConfig(download: true, load: false, verbose: false)
        let speakerKit = try await SpeakerKit(config)

        // Build diarization options, forwarding numSpeakers when provided.
        let options = PyannoteDiarizationOptions(numberOfSpeakers: numSpeakers)

        Logger.transcription.info("SpeakerKit: running Pyannote pipeline (numSpeakers=\(numSpeakers.map(String.init) ?? "auto", privacy: .public))")
        let result = try await speakerKit.diarize(audioArray: audioArray, options: options)

        // Map SpeakerKit segments to DiarizedSegment.
        // speaker.speakerId is an Int? — fall back to "SPEAKER_unknown" when absent.
        let segments: [DiarizedSegment] = result.segments.map { seg in
            let speakerLabel: String
            if let id = seg.speaker.speakerId {
                speakerLabel = String(format: "SPEAKER_%02d", id)
            } else {
                speakerLabel = "SPEAKER_unknown"
            }
            return DiarizedSegment(
                start: Double(seg.startTime),
                end: Double(seg.endTime),
                speaker: speakerLabel
            )
        }

        let elapsed = ContinuousClock.now - startTime
        let speakerCount = Set(segments.map(\.speaker)).count
        Logger.transcription.info(
            "SpeakerKit diarization complete: \(segments.count) segments, \(speakerCount) speakers in \(elapsed.components.seconds)s"
        )

        return segments
    }
}
