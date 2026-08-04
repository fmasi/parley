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
        anomalyCount > 0 ? "Transcription Complete — capture anomalies" : "Transcription Complete"
    }

    /// Notification body. Names the count so the user knows to look, and where.
    public static func completionBody(fileName: String, anomalyCount: Int) -> String {
        guard anomalyCount > 0 else { return fileName }
        let noun = anomalyCount == 1 ? "anomaly" : "anomalies"
        return "\(fileName) — \(anomalyCount) capture \(noun) recorded; audio may be affected"
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
    public static func anomalyCount(inTranscriptAt url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = root["metadata"] as? [String: Any],
              let provenance = metadata["capture_provenance"] as? [String: Any]
        else { return 0 }
        // Transcripts written before this field existed simply have no quality signal — absent means
        // 0, never a retroactive alarm.
        if let count = provenance["quality_anomaly_count"] as? Int { return count }
        if let count = provenance["quality_anomaly_count"] as? NSNumber { return count.intValue }
        return 0
    }
}
