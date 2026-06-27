import Foundation
import os

public enum TranscriptAssembler {

    public static func assemble(
        segments: [LabeledSegment],
        audioPaths: [URL],
        outputFormat: String,
        language: String,
        numSpeakers: Int?,
        diarization: Bool,
        dualStream: Bool,
        echoSegmentsRemoved: Int = 0,
        provenance: CaptureProvenance? = nil,
        recordedAt: Date? = nil
    ) -> [String: Any] {
        var metadata: [String: Any] = [
            "audio_files": audioPaths.map { $0.lastPathComponent },
            "audio_paths": audioPaths.map { $0.path },
            "output_format": outputFormat,
            "language": language,
            "num_speakers": numSpeakers.map { $0 as Any } ?? ("auto" as Any),
            "diarization": diarization,
            "dual_stream": dualStream,
            "software_version": AppVersion.gitDescription,
        ]
        // Recording-start wall-clock time (#49): the canonical date of the meeting. Stamped
        // here so summaries (and any downstream consumer) date the record by when it was
        // recorded, not when it was later transcribed/summarized. ISO8601 for stable parsing.
        if let recordedAt {
            metadata["recorded_at"] = ISO8601DateFormatter().string(from: recordedAt)
        }
        if echoSegmentsRemoved > 0 {
            metadata["echo_segments_removed"] = echoSegmentsRemoved
        }
        // Capture provenance (#95): a compact, always-present stamp of how this recording was
        // captured — engine, formats, and how many route changes / retries / recoveries occurred.
        if let provenance {
            metadata["capture_provenance"] = provenance.asMetadataDictionary()
        }

        let segmentDicts: [[String: Any]] = segments.map { seg in
            var dict: [String: Any] = [
                "start": seg.start,
                "end": seg.end,
                "speaker": seg.speaker,
                "text": seg.text,
            ]
            if !seg.source.isEmpty {
                dict["source"] = seg.source
            }
            if let confidence = seg.confidence {
                dict["confidence"] = confidence
            }
            if let language = seg.language {
                dict["language"] = language
            }
            return dict
        }

        Logger.transcription.debug("Assembled transcript: \(segments.count) segments, format: \(outputFormat, privacy: .public)")

        return [
            "metadata": metadata,
            "segments": segmentDicts,
        ]
    }

    public static func write(_ json: [String: Any], to path: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: path, options: .atomic)
        Logger.files.info("JSON transcript written: \(path.lastPathComponent, privacy: .private)")
    }

    /// Rewrite a transcript JSON's `audio_paths` / `audio_files` to reference every audio source
    /// that contributed to it, replacing the placeholder source-WAV paths written at assembly
    /// time (#93). No-op if the file is missing or unreadable.
    public static func reconcileAudioPaths(in jsonPath: URL, to paths: [URL]) {
        guard let data = try? Data(contentsOf: jsonPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var metadata = json["metadata"] as? [String: Any]
        else { return }

        metadata["audio_paths"] = paths.map { $0.path }
        metadata["audio_files"] = paths.map { $0.lastPathComponent }
        json["metadata"] = metadata

        guard let updated = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? updated.write(to: jsonPath, options: .atomic)
        Logger.files.info("Reconciled audio paths in \(jsonPath.lastPathComponent, privacy: .private) → \(paths.count) source(s)")
    }
}
