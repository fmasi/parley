import Foundation
import os

public enum TranscriptWriter {
    /// Format seconds as HH:MM:SS,mmm (SRT format).
    static func formatTimestamp(_ seconds: Double) -> String {
        let totalMs = Int(seconds * 1000)
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1000
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// Format seconds as HH:MM:SS (TXT format).
    static func formatTimestampShort(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Format segments as plain text with timestamps. Flagged segments (`filtered` / `echo`) are
    /// kept in the JSON record but not rendered (P10/P11).
    static func formatTXT(segments: [[String: Any]]) -> String {
        var result = ""
        for seg in segments where !TranscriptAssembler.isFlagged(seg) {
            let ts = formatTimestampShort(seg["start"] as? Double ?? 0)
            let speaker = seg["speaker"] as? String ?? ""
            let text = seg["text"] as? String ?? ""
            let prefix = speaker.isEmpty ? "" : "\(speaker): "
            result += "[\(ts)] \(prefix)\(text)\n"
        }
        return result + omissionNote(segments)
    }

    /// A trailing line when segments without a usable time were left out: the file itself says so,
    /// not only the log (round 3 item 8). Empty when nothing was left out.
    static func omissionNote(_ segments: [[String: Any]]) -> String {
        let n = segments.filter { !TranscriptAssembler.hasUsableTime($0) }.count
        guard n > 0 else { return "" }
        let what = n == 1 ? "1 segment without a timestamp is" : "\(n) segments without timestamps are"
        return "\nNote: \(what) in the JSON transcript.\n"
    }

    /// Format segments as SRT subtitle text. Flagged segments are skipped and the cue numbers stay
    /// consecutive.
    static func formatSRT(segments: [[String: Any]]) -> String {
        var result = ""
        for (i, seg) in segments.filter({ !TranscriptAssembler.isFlagged($0) }).enumerated() {
            let start = formatTimestamp(seg["start"] as? Double ?? 0)
            let end = formatTimestamp(seg["end"] as? Double ?? 0)
            let speaker = seg["speaker"] as? String ?? ""
            let text = seg["text"] as? String ?? ""
            let prefix = speaker.isEmpty ? "" : "\(speaker): "
            result += "\(i + 1)\n\(start) --> \(end)\n\(prefix)\(text)\n\n"
        }
        // After the last cue's blank line, so every cue stays well formed.
        return result + String(omissionNote(segments).dropFirst())
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
        let untimed = segments.filter { !TranscriptAssembler.hasUsableTime($0) }.count
        if untimed > 0 {
            Logger.files.error("\(untimed, privacy: .public) segment(s) have no usable time — left out of the \(format, privacy: .public) (kept in the JSON, flagged)")
        }

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
