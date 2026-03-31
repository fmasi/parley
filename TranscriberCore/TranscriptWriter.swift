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
}
