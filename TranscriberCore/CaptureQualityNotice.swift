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

    /// What each `…(inTranscriptAt:)` reader answers when the transcript can't be read back (missing,
    /// unreadable, not a transcript). Not an alarm about the audio — but not "nothing wrong" either:
    /// answering 0/0/1 for a file nobody read turned it into a plain "Transcription Complete". The
    /// title and body then say the transcript could not be checked. A sentinel rather than an
    /// optional, so the one call site (`RecordingCoordinator.presentCompletedTranscription`) needs no
    /// change to be honest.
    public static let unreadable = -1

    private static let couldNotCheck = "Parley couldn't re-read the transcript to check it"

    /// Notification title for a completed transcription, with precedence unreadable > no speech > a side
    /// not captured > a side partly captured > a side briefly affected > capture anomalies > processing problems > echo marked >
    /// complete (§7.3).
    ///
    /// A transcript that could not be re-read leads: none of the others can be known, and
    /// "Complete" would be a clean bill for a file nobody checked. An empty transcript comes next:
    /// "Transcription Complete" over a file with no words in it is the most misleading thing this
    /// notice could say. The per-side verdict (`capture_provenance.<side>_coverage.status`, the fact the
    /// summary banner uses) comes before the ring's anomalies: a side that delivered nothing may carry no
    /// anomaly at all — a crashed helper's undrained ring, a recording too short to judge live (final review
    /// R-I2). Anomalies beat processing problems because they mean the AUDIO itself may be wrong; the body
    /// still names every side and every non-zero count.
    ///
    /// `remoteStatus` / `localStatus`: a `TrackAccounting.Status` raw value, nil when the record has none
    /// (never an invented alarm); `idle` and `healthy` say nothing.
    ///
    /// `echoLines`: `EchoNotice.Findings.completionLines` — above 0 when the recording has an echo voice
    /// (#244). Last in the precedence: the lines are marked and nothing is missing, so it is information,
    /// never said in place of a problem. The body carries it either way.
    public static func completionTitle(anomalyCount: Int, problemChunkCount: Int, segmentCount: Int,
                                       remoteStatus: String? = nil, localStatus: String? = nil, echoLines: Int = 0) -> String {
        if [anomalyCount, problemChunkCount, segmentCount].contains(unreadable) { return "Transcription finished — \(couldNotCheck)" }
        if segmentCount == 0 { return "Transcription Complete — no speech was transcribed" }
        let remote = side(remoteStatus), local = side(localStatus)
        switch (remote, local) {
        case (.neverDelivered?, .neverDelivered?): return "Transcription Complete — neither side was captured"
        case (.neverDelivered?, _): return "Transcription Complete — the other side was not captured"
        case (_, .neverDelivered?): return "Transcription Complete — your microphone was not captured"
        case (.compromised?, _), (_, .compromised?): return "Transcription Complete — capture compromised"
        // A drift healed in seconds (#308): said, but not as a compromised capture.
        case (.degraded?, _), (_, .degraded?): return "Transcription Complete — brief capture glitch"
        default: break
        }
        if anomalyCount > 0 { return "Transcription Complete — capture anomalies" }
        if problemChunkCount > 0 { return "Transcription Complete — \(problemPhrase(problemChunkCount))" }
        if echoLines > 0 { return "Transcription Complete — \(EchoNotice.completionTitle)" }
        return "Transcription Complete"
    }

    /// Notification body: the file name, then each side not (or partly) captured, then every non-zero count,
    /// then the echo voice (`echoLines`, as for the title).
    /// `removedRecordings` (#224): how many older recordings lost their audio to the storage limit — a line of its own.
    public static func completionBody(fileName: String, anomalyCount: Int, problemChunkCount: Int, segmentCount: Int,
                                      remoteStatus: String? = nil, localStatus: String? = nil, echoLines: Int = 0,
                                      removedRecordings: Int = 0) -> String {
        let body = recordBody(fileName: fileName, anomalyCount: anomalyCount, problemChunkCount: problemChunkCount, segmentCount: segmentCount,
                              remoteStatus: remoteStatus, localStatus: localStatus, echoLines: echoLines)
        guard let line = storageLimitLine(removedRecordings: removedRecordings) else { return body }
        return body + "\n" + line
    }

    /// The completion notice's line when the storage limit removed older audio (#224); nil when nothing was removed.
    public static func storageLimitLine(removedRecordings count: Int) -> String? {
        guard count > 0 else { return nil }
        let noun = count == 1 ? "recording" : "recordings"
        return "Removed the audio of \(count) older \(noun) to stay within the storage limit; transcripts are kept."
    }

    private static func recordBody(fileName: String, anomalyCount: Int, problemChunkCount: Int, segmentCount: Int,
                                   remoteStatus: String?, localStatus: String?, echoLines: Int) -> String {
        if [anomalyCount, problemChunkCount, segmentCount].contains(unreadable) { return "\(fileName) — \(couldNotCheck)" }
        var parts: [String] = []
        if segmentCount == 0 { parts.append("no speech was transcribed") }
        for (name, status) in [("remote audio", side(remoteStatus)), ("microphone", side(localStatus))] {
            switch status {
            case .neverDelivered?: parts.append("\(name) not captured")
            case .compromised?: parts.append("\(name) partly captured")
            case .degraded?: parts.append("\(name) briefly affected")
            default: break
            }
        }
        if anomalyCount > 0 {
            let noun = anomalyCount == 1 ? "anomaly" : "anomalies"
            parts.append("\(anomalyCount) capture \(noun) recorded; audio may be affected")
        }
        if problemChunkCount > 0 { parts.append(problemPhrase(problemChunkCount)) }
        if let echo = EchoNotice.completionNotice(lines: echoLines) { parts.append(echo) }
        guard !parts.isEmpty else { return fileName }
        return "\(fileName) — " + parts.joined(separator: "; ")
    }

    /// A side's verdict worth saying: `neverDelivered`, `compromised` or `degraded`; nil otherwise (absent, unknown, idle,
    /// healthy).
    private static func side(_ status: String?) -> TrackAccounting.Status? {
        switch status.flatMap(TrackAccounting.Status.init(rawValue:)) {
        case .neverDelivered?: return .neverDelivered
        case .compromised?: return .compromised
        case .degraded?: return .degraded
        default: return nil
        }
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
    /// Returns 0 when the field is absent (never invent an alarm), `unreadable` when the transcript
    /// itself can't be read back.
    ///
    /// - Important: synchronous file I/O. A long meeting's transcript can reach several hundred KB,
    ///   so call this OFF the main actor (`RecordingCoordinator` uses a detached task) — blocking
    ///   the UI to decide how to phrase a notification would be a poor trade.
    public static func anomalyCount(inTranscriptAt url: URL) -> Int {
        guard let root = readRoot(url) else { return unreadable }
        guard let metadata = root["metadata"] as? [String: Any],
              let provenance = metadata["capture_provenance"] as? [String: Any]
        else { return 0 }
        // Transcripts written before this field existed simply have no quality signal — absent means
        // 0, never a retroactive alarm.
        // `as? Int` already bridges the NSNumber that JSONSerialization produces for JSON integers.
        return provenance["quality_anomaly_count"] as? Int ?? 0
    }

    /// Distinct chunks with a content-affecting processing issue, computed from
    /// `metadata.processing_issues` itself — never a stored summary key that could disagree with it.
    /// 0 when absent (never invent an alarm), `unreadable` when the transcript can't be read back.
    /// Synchronous file I/O — call off the main actor, like `anomalyCount(inTranscriptAt:)`.
    public static func problemChunkCount(inTranscriptAt url: URL) -> Int {
        guard let root = readRoot(url) else { return unreadable }
        guard let metadata = root["metadata"] as? [String: Any],
              let issues = metadata["processing_issues"] as? [[String: Any]]
        else { return 0 }
        return ChunkIssue.problemCounts(in: issues).chunks
    }

    /// How many readable segments the transcript holds — flagged ones (`filtered` / `echo`) are
    /// hidden from every rendering, so they are not speech anyone can read. A file that can't be
    /// read back, or holds no segment list, answers `unreadable`, not 0: failing to read it is not
    /// evidence that no speech was transcribed, and "no speech" is an alarm.
    public static func segmentCount(inTranscriptAt url: URL) -> Int {
        guard let segments = readRoot(url)?["segments"] as? [[String: Any]] else { return unreadable }
        return segments.filter { !TranscriptAssembler.isFlagged($0) }.count
    }

    /// Each side's verdict, `metadata.capture_provenance.{remote,local}_coverage.status` — the fact the summary banner
    /// uses (final review R-I2). nil when the transcript can't be read back (the caller says it could not check); each
    /// side nil when its key is absent (never an invented alarm). Synchronous file I/O — call off the main actor, like
    /// `anomalyCount(inTranscriptAt:)`.
    public static func sideStatuses(inTranscriptAt url: URL) -> (remote: String?, local: String?)? {
        guard let root = readRoot(url) else { return nil }
        let provenance = (root["metadata"] as? [String: Any])?["capture_provenance"] as? [String: Any]
        func status(_ key: String) -> String? { (provenance?[key] as? [String: Any])?["status"] as? String }
        return (status("remote_coverage"), status("local_coverage"))
    }

    private static func readRoot(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
