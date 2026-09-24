import Foundation

/// What a salvage actually did (§7.4 P6). The message must never claim a transcript that does not exist.
public struct SalvageOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case transcriptWritten(URL), nothingToSalvage, finalizeFailed(String) }
    public let kind: Kind
    public let chunkCount: Int
    /// The in-progress chunk was re-ingested but did not make it into the written transcript: its
    /// audio is on disk, untranscribed (L6 fix round 1).
    public let lastChunkKeptOnDisk: Bool
    public init(kind: Kind, chunkCount: Int, lastChunkKeptOnDisk: Bool = false) {
        // Chunks on disk are never "no recorded audio": callers report them as kept (`finalizeFailed`).
        assert(!(kind == .nothingToSalvage && chunkCount > 0), "nothingToSalvage with \(chunkCount) chunks on disk")
        self.kind = kind; self.chunkCount = chunkCount; self.lastChunkKeptOnDisk = lastChunkKeptOnDisk
    }
}

public enum RecoveryMessages {
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    public static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    /// Noun phrase plus subject-verb agreement for a chunk count (review fix 7): "1 chunk"/"was"/"is"
    /// vs "N chunks"/"were"/"are". Only called for a count ≥ 1 — `outcomeSentence` handles 0 itself (fix 8).
    private static func chunkPhrase(_ n: Int) -> (noun: String, wasWere: String, isAre: String) {
        n == 1 ? ("1 chunk", "was", "is") : ("\(n) chunks", "were", "are")
    }

    /// What the salvage did, as one sentence (the alerts, and the menu banners).
    public static func outcomeSentence(_ outcome: SalvageOutcome) -> String {
        switch outcome.kind {
        case .transcriptWritten(let url):
            let tail = outcome.lastChunkKeptOnDisk ? " The last chunk is kept on disk, not transcribed." : ""
            guard outcome.chunkCount > 0 else {
                return "No chunks were recorded, but a transcript was written to \(url.lastPathComponent)." + tail
            }
            let (noun, wasWere, _) = chunkPhrase(outcome.chunkCount)
            return "The \(noun) recorded before it \(wasWere) transcribed to \(url.lastPathComponent)." + tail
        case .nothingToSalvage:
            // Only when nothing of the session is on disk (asserted at construction: chunkCount == 0).
            // With chunks there, callers report them as kept but not transcribed (`finalizeFailed`).
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
        "Capture failed and could not be restarted. " + outcomeSentence(outcome)
    }

    /// The helper's stop itself failed.
    public static func stopFailed(after outcome: SalvageOutcome, error: String) -> String {
        "Stopping the recording failed\(errorClause(error, unlessIn: outcome)). " + outcomeSentence(outcome)
    }

    /// The stop succeeded; finishing the transcript afterwards failed (L6 fix round 1). When the
    /// salvage then wrote it after all, that is what it says (L round 5): no "could not be finished".
    public static func transcriptionFailed(after outcome: SalvageOutcome, error: String) -> String {
        if case .transcriptWritten(let url) = outcome.kind {
            let what = outcome.chunkCount > 0 ? "the \(chunkPhrase(outcome.chunkCount).noun)" : "the recording"
            let tail = outcome.lastChunkKeptOnDisk ? " The last chunk is kept on disk, not transcribed." : ""
            return "The recording stopped. The first attempt to finish its transcript failed (\(error)); Parley recovered and transcribed \(what) to \(url.lastPathComponent)." + tail
        }
        return "The recording stopped, but its transcript could not be finished\(errorClause(error, unlessIn: outcome)). " + outcomeSentence(outcome)
    }

    /// The alert title after a stop that did not end in a normal transcript. It follows the outcome: a
    /// salvaged transcript never says "Failed".
    public static func stopFailureTitle(after outcome: SalvageOutcome, stopSucceeded: Bool) -> String {
        switch outcome.kind {
        case .transcriptWritten: return "Transcript Saved After an Error"
        case .finalizeFailed: return "Transcription Failed"
        case .nothingToSalvage: return stopSucceeded ? "Transcription Failed" : "Stopping the Recording Failed"
        }
    }

    /// " (error)", omitted when the outcome sentence already names the same error.
    private static func errorClause(_ error: String, unlessIn outcome: SalvageOutcome) -> String {
        if case .finalizeFailed(let why) = outcome.kind, why == error { return "" }
        return " (\(error))"
    }

    /// Parley was quit (or the user logged out) while the stopped recording's transcript was being finished
    /// (L follow-up 42): a deliberate exit, not a crash.
    public static func quitWhileFinishing(outcome: SalvageOutcome) -> String {
        if case .transcriptWritten(let url) = outcome.kind {
            let what = outcome.chunkCount > 0 ? chunkPhrase(outcome.chunkCount).noun : "the recording"
            let tail = outcome.lastChunkKeptOnDisk ? " The last chunk is kept on disk, not transcribed." : ""
            return "Parley was quit while finishing the transcript; it recovered \(what) to \(url.lastPathComponent)." + tail
        }
        return "Parley was quit while finishing the transcript. " + outcomeSentence(outcome)
    }

    /// A pre-0.6 single-file recording was found (L follow-up 25): kept, never "no recorded audio". Names
    /// the folder, not the meeting.
    public static func relaunchStoppedKeepingOlderFormat(at: Date, folder: String) -> String {
        "Recording STOPPED at \(clock(at)) — Parley crashed and could not resume it. An older-format recording was found and kept in \(folder)."
    }

    public static func relaunchStopped(at: Date, outcome: SalvageOutcome) -> String {
        "Recording STOPPED at \(clock(at)) — Parley crashed and could not resume it. " + outcomeSentence(outcome)
    }

    /// Review fix 9: the wall clock can step back across a crash/resume pair; the reported gap is
    /// clamped to ≥ 0 rather than printing a negative duration.
    public static func resumedAfterCrash(crashedAt: Date, resumedAt: Date) -> String {
        let gap = max(0, Int(resumedAt.timeIntervalSince(crashedAt).rounded()))
        return "Parley crashed at \(clock(crashedAt)) and resumed at \(clock(resumedAt)) — \(gap) s not recorded."
    }
}
