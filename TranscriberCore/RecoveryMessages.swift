import Foundation

/// What a salvage actually did (§7.4 P6). The message must never claim a transcript that does not exist.
public struct SalvageOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case transcriptWritten(URL), nothingToSalvage, finalizeFailed(String) }
    public let kind: Kind
    public let chunkCount: Int
    /// Chunks among `chunkCount` whose speech recognition failed (C-M13, R2b item 9), per track: a
    /// chunk is untranscribed only for the tracks that failed. The transcript holds no words for
    /// those, so they must not be called "transcribed".
    public struct RecognitionFailures: Equatable, Sendable {
        /// Every track the chunk had failed (both sides, or the only side of a system-only chunk).
        public var wholeChunks: Int
        /// Only the other side (remote) failed; the microphone's words are in the transcript.
        public var remoteOnly: Int
        /// Only the microphone failed; the other side's words are in the transcript.
        public var localOnly: Int
        public init(wholeChunks: Int = 0, remoteOnly: Int = 0, localOnly: Int = 0) {
            self.wholeChunks = wholeChunks; self.remoteOnly = remoteOnly; self.localOnly = localOnly
        }
    }
    public let recognitionFailures: RecognitionFailures
    public init(kind: Kind, chunkCount: Int, recognitionFailures: RecognitionFailures = .init()) {
        self.kind = kind
        self.chunkCount = chunkCount
        self.recognitionFailures = recognitionFailures
    }

    /// Counted from the chunks' own `asr_failed` issues. An issue with no track fails the chunk.
    public static func recognitionFailures(in chunks: [ProcessedChunk]) -> RecognitionFailures {
        var result = RecognitionFailures()
        for chunk in chunks {
            let failed = chunk.issues.filter { $0.code == .asrFailed }
            guard !failed.isEmpty else { continue }
            let remote = failed.contains { $0.track == "remote" || $0.track == nil }
            let local = failed.contains { $0.track == "local" || $0.track == nil }
            if (remote && local) || (remote && !chunk.isDualStream) { result.wholeChunks += 1 }
            else if remote { result.remoteOnly += 1 }
            else { result.localOnly += 1 }
        }
        return result
    }
}

public enum RecoveryMessages {
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    public static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    /// Noun phrase plus subject-verb agreement for a chunk count (review fix 7): "1 chunk"/"was"/"is"
    /// vs "N chunks"/"were"/"are". Only called for a count ≥ 1 — `describe` handles 0 itself (fix 8).
    private static func chunkPhrase(_ n: Int) -> (noun: String, wasWere: String, isAre: String) {
        n == 1 ? ("1 chunk", "was", "is") : ("\(n) chunks", "were", "are")
    }

    private static func describe(_ outcome: SalvageOutcome) -> String {
        switch outcome.kind {
        case .transcriptWritten(let url):
            guard outcome.chunkCount > 0 else {
                return "No chunks were recorded, but a transcript was written to \(url.lastPathComponent)."
            }
            let (noun, wasWere, _) = chunkPhrase(outcome.chunkCount)
            if let allFailed = allFailed(outcome) {
                return "The \(noun) recorded before it \(wasWere) written to \(url.lastPathComponent), but \(allFailed)."
            }
            return "The \(noun) recorded before it \(wasWere) transcribed to \(url.lastPathComponent)\(recognitionClauses(outcome))."
        case .nothingToSalvage:
            // Review fix 6: callers map both "no processor" and "salvage returned nil" to this case
            // even when audio exists — never claim a specific cause the type can't know.
            return "No transcript could be written: no recorded audio was found to salvage."
        case .finalizeFailed(let why):
            guard outcome.chunkCount > 0 else {
                return "No chunks were recorded, and finalizing failed: \(why)."
            }
            let (noun, _, isAre) = chunkPhrase(outcome.chunkCount)
            return "The \(noun) recorded before it \(isAre) kept on disk but could not be transcribed: \(why)."
        }
    }

    public static func recordingFailed(after outcome: SalvageOutcome) -> String {
        "Capture failed and could not be restarted. " + describe(outcome)
    }

    public static func stopFailed(after outcome: SalvageOutcome, error: String) -> String {
        "Stopping the recording failed (\(error)). " + describe(outcome)
    }

    /// A stale-boot salvage: the Mac restarted (or lost power) during the recording (R2 follow-up 1).
    /// "Parley crashed" would name the wrong cause.
    public static func relaunchStoppedByRestart(at: Date, outcome: SalvageOutcome) -> String {
        let cause = "Recording STOPPED at \(clock(at)) — your Mac restarted during the recording. "
        guard case .transcriptWritten(let url) = outcome.kind, outcome.chunkCount > 0 else { return cause + describe(outcome) }
        let (noun, _, _) = chunkPhrase(outcome.chunkCount)
        if let allFailed = allFailed(outcome) {
            return cause + "Parley recovered \(noun) to \(url.lastPathComponent), but \(allFailed)."
        }
        return cause + "Parley recovered \(noun) to \(url.lastPathComponent)\(recognitionClauses(outcome))."
    }

    /// "speech recognition failed on it / all of them" when every chunk failed on every track.
    private static func allFailed(_ outcome: SalvageOutcome) -> String? {
        guard outcome.recognitionFailures.wholeChunks >= outcome.chunkCount else { return nil }
        return "speech recognition failed on \(outcome.chunkCount == 1 ? "it" : "all of them")"
    }

    /// "; speech recognition failed on N of them; the other side's … in N of them; …", per side.
    private static func recognitionClauses(_ outcome: SalvageOutcome) -> String {
        let f = outcome.recognitionFailures
        var clauses: [String] = []
        if f.wholeChunks > 0 { clauses.append("speech recognition failed on \(f.wholeChunks) of them") }
        if f.remoteOnly > 0 { clauses.append("the other side's speech could not be recognised in \(f.remoteOnly) of them") }
        if f.localOnly > 0 { clauses.append("your microphone's speech could not be recognised in \(f.localOnly) of them") }
        return clauses.map { "; " + $0 }.joined()
    }

    public static func relaunchStopped(at: Date, outcome: SalvageOutcome) -> String {
        "Recording STOPPED at \(clock(at)) — Parley crashed and could not resume it. " + describe(outcome)
    }

    /// Review fix 9: the wall clock can step back across a crash/resume pair; the reported gap is
    /// clamped to ≥ 0 rather than printing a negative duration.
    public static func resumedAfterCrash(crashedAt: Date, resumedAt: Date) -> String {
        let gap = max(0, Int(resumedAt.timeIntervalSince(crashedAt).rounded()))
        return "Parley crashed at \(clock(crashedAt)) and resumed at \(clock(resumedAt)) — \(gap) s not recorded."
    }
}
