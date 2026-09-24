import Foundation

/// What a salvage actually did (§7.4 P6). The message must never claim a transcript that does not exist.
public struct SalvageOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case transcriptWritten(URL), nothingToSalvage, finalizeFailed(String) }
    public let kind: Kind
    public let chunkCount: Int
    /// Chunks among `chunkCount` whose speech recognition failed (C-M13): the transcript holds no
    /// words for them, so they must not be called "transcribed".
    public let untranscribedChunkCount: Int
    public init(kind: Kind, chunkCount: Int, untranscribedChunkCount: Int = 0) {
        self.kind = kind
        self.chunkCount = chunkCount
        self.untranscribedChunkCount = untranscribedChunkCount
    }

    /// The chunks whose speech recognition failed on any track (an `asr_failed` issue).
    public static func untranscribedChunkCount(in chunks: [ProcessedChunk]) -> Int {
        chunks.filter { $0.issues.contains { $0.code == .asrFailed } }.count
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
            let failed = min(outcome.untranscribedChunkCount, outcome.chunkCount)
            if failed == outcome.chunkCount {
                let which = outcome.chunkCount == 1 ? "it" : "all of them"
                return "The \(noun) recorded before it \(wasWere) written to \(url.lastPathComponent), but speech recognition failed on \(which)."
            }
            let recognitionFailed = failed > 0 ? "; speech recognition failed on \(failed) of them" : ""
            return "The \(noun) recorded before it \(wasWere) transcribed to \(url.lastPathComponent)\(recognitionFailed)."
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
