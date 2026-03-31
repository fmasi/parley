import Foundation

public enum TranscriptWriter {
    /// Format seconds as HH:MM:SS,mmm (SRT format).
    static func formatTimestamp(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// Format seconds as HH:MM:SS (TXT format).
    static func formatTimestampShort(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Format segments as plain text with timestamps.
    static func formatTXT(segments: [[String: Any]]) -> String {
        var result = ""
        for seg in segments {
            let ts = formatTimestampShort(seg["start"] as? Double ?? 0)
            let speaker = seg["speaker"] as? String ?? ""
            let text = seg["text"] as? String ?? ""
            let prefix = speaker.isEmpty ? "" : "\(speaker): "
            result += "[\(ts)] \(prefix)\(text)\n"
        }
        return result
    }

    /// Format segments as SRT subtitle text.
    static func formatSRT(segments: [[String: Any]]) -> String {
        var result = ""
        for (i, seg) in segments.enumerated() {
            let start = formatTimestamp(seg["start"] as? Double ?? 0)
            let end = formatTimestamp(seg["end"] as? Double ?? 0)
            let speaker = seg["speaker"] as? String ?? ""
            let text = seg["text"] as? String ?? ""
            let prefix = speaker.isEmpty ? "" : "\(speaker): "
            result += "\(i + 1)\n\(start) --> \(end)\n\(prefix)\(text)\n\n"
        }
        return result
    }

    public enum WriterError: Error {
        case invalidJSON
    }

    /// Generate a format file (.srt or .txt) from a JSON transcript.
    /// Reads segments and output_format from the JSON metadata.
    /// Writes the format file alongside the JSON (same directory, same base name).
    /// No-op if output_format is "json" or missing.
    public static func writeFormatFile(fromJSON jsonPath: URL) throws {
        let data = try Data(contentsOf: jsonPath)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["segments"] as? [[String: Any]],
              let metadata = json["metadata"] as? [String: Any]
        else { throw WriterError.invalidJSON }

        let format = metadata["output_format"] as? String ?? "json"
        guard format != "json" else { return }

        let content: String
        switch format {
        case "srt":
            content = formatSRT(segments: segments)
        case "txt":
            content = formatTXT(segments: segments)
        default:
            return
        }

        let outputPath = jsonPath.deletingPathExtension().appendingPathExtension(format)
        try content.write(to: outputPath, atomically: true, encoding: .utf8)
    }
}
