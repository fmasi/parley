import Foundation

/// Whether a finished recording should present as trustworthy.
///
/// On 2026-08-04 the capture layer knew, five seconds in, that the remote track was being written at
/// the wrong rate. It recorded that faithfully into `capture_provenance` and the `.diag.jsonl`. Then
/// the app posted "Transcription Complete" and opened the rename dialog exactly as it does for a
/// clean recording, and the user discovered the corruption by ear two hours later.
///
/// For a tool whose purpose is a courtroom-grade record of a meeting, filing an exhibit the system
/// already knows is tainted — without saying so — is worse than never having detected it. The
/// knowledge existed; nothing carried it to the human. This type is that carrier.
public enum CaptureQualityNotice {

    /// Notification title for a completed transcription.
    public static func completionTitle(anomalyCount: Int) -> String {
        completionTitle(anomalyCount: anomalyCount, problemChunkCount: 0, segmentCount: 1)
    }

    /// Notification body. Names the count so the user knows to look, and where.
    public static func completionBody(fileName: String, anomalyCount: Int) -> String {
        completionBody(fileName: fileName, anomalyCount: anomalyCount, problemChunkCount: 0, segmentCount: 1)
    }

    /// Notification title for a completed transcription — exactly one of four, with precedence
    /// no speech > capture anomalies > processing problems > complete (§7.3).
    ///
    /// An empty transcript leads: "Transcription Complete" over a file with no words in it is the
    /// most misleading thing this notice could say. Anomalies beat processing problems because they
    /// mean the AUDIO itself may be wrong; the body still names every non-zero count.
    public static func completionTitle(anomalyCount: Int, problemChunkCount: Int, segmentCount: Int) -> String {
        if segmentCount == 0 { return "Transcription Complete — no speech was transcribed" }
        if anomalyCount > 0 { return "Transcription Complete — capture anomalies" }
        if problemChunkCount > 0 { return "Transcription Complete — \(problemPhrase(problemChunkCount))" }
        return "Transcription Complete"
    }

    /// Notification body: the file name, then every non-zero count.
    public static func completionBody(fileName: String, anomalyCount: Int, problemChunkCount: Int, segmentCount: Int) -> String {
        var parts: [String] = []
        if segmentCount == 0 { parts.append("no speech was transcribed") }
        if anomalyCount > 0 {
            let noun = anomalyCount == 1 ? "anomaly" : "anomalies"
            parts.append("\(anomalyCount) capture \(noun) recorded; audio may be affected")
        }
        if problemChunkCount > 0 { parts.append(problemPhrase(problemChunkCount)) }
        guard !parts.isEmpty else { return fileName }
        return "\(fileName) — " + parts.joined(separator: "; ")
    }

    private static func problemPhrase(_ count: Int) -> String {
        count == 1 ? "1 chunk had processing problems" : "\(count) chunks had processing problems"
    }

    /// Read the CONTENT-compromising anomaly count a transcript carries in
    /// `metadata.capture_provenance.quality_anomaly_count`.
    ///
    /// Deliberately NOT `anomaly_count`: that includes `.streamStopError`, which is recorded for a
    /// benign Bluetooth route change and fires on nearly every recording made on the default source
    /// with wireless headphones. Reading it would brand healthy recordings as suspect and destroy the
    /// signal on arrival. See `CaptureEventKind.qualityCompromising`.
    ///
    /// Reading it back from the artifact (rather than threading it through every call site) means the
    /// crash-recovery and salvage paths get the same treatment as a clean stop for free — those are
    /// exactly the paths where a compromised capture is most likely and least examined.
    /// Returns 0 when absent or unreadable: never invent an alarm.
    ///
    /// - Important: synchronous file I/O. A long meeting's transcript can reach several hundred KB,
    ///   so call this OFF the main actor (`RecordingCoordinator` uses a detached task) — blocking
    ///   the UI to decide how to phrase a notification would be a poor trade.
    public static func anomalyCount(inTranscriptAt url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = root["metadata"] as? [String: Any],
              let provenance = metadata["capture_provenance"] as? [String: Any]
        else { return 0 }
        // Transcripts written before this field existed simply have no quality signal — absent means
        // 0, never a retroactive alarm.
        // `as? Int` already bridges the NSNumber that JSONSerialization produces for JSON integers.
        return provenance["quality_anomaly_count"] as? Int ?? 0
    }

    /// Distinct chunks with a content-affecting processing issue, from
    /// `metadata.processing_problem_chunks`. 0 when absent or unreadable (never invent an alarm).
    /// Synchronous file I/O — call off the main actor, like `anomalyCount(inTranscriptAt:)`.
    public static func problemChunkCount(inTranscriptAt url: URL) -> Int {
        guard let metadata = readRoot(url)?["metadata"] as? [String: Any] else { return 0 }
        return metadata["processing_problem_chunks"] as? Int ?? 0
    }

    /// How many readable segments the transcript holds — flagged ones (`filtered` / `echo`) are
    /// hidden from every rendering, so they are not speech anyone can read. An unreadable file
    /// answers 1, not 0: failing to read the file is not evidence that no speech was transcribed,
    /// and "no speech" is an alarm.
    public static func segmentCount(inTranscriptAt url: URL) -> Int {
        guard let segments = readRoot(url)?["segments"] as? [[String: Any]] else { return 1 }
        return segments.filter { !TranscriptAssembler.isFlagged($0) }.count
    }

    private static func readRoot(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
