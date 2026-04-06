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
        echoSegmentsRemoved: Int = 0
    ) -> [String: Any] {
        var metadata: [String: Any] = [
            "audio_files": audioPaths.map { $0.lastPathComponent },
            "audio_paths": audioPaths.map { $0.path },
            "output_format": outputFormat,
            "language": language,
            "num_speakers": numSpeakers.map { $0 as Any } ?? ("auto" as Any),
            "diarization": diarization,
            "dual_stream": dualStream,
        ]
        if echoSegmentsRemoved > 0 {
            metadata["echo_segments_removed"] = echoSegmentsRemoved
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
        Logger.files.info("JSON transcript written: \(path.lastPathComponent, privacy: .public)")
    }
}
