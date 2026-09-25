import Foundation

/// What a salvage actually did (§7.4 P6). The message must never claim a transcript that does not exist.
public struct SalvageOutcome: Equatable, Sendable {
    /// `folderNotAnswering`: the recording folder did not answer, so nothing could be checked or salvaged; its audio
    /// is kept (L review 122). `transcriptUnreadable`: a finished session's transcript cannot be read back and there is
    /// no progress file to rebuild it from — it and its audio are kept as they are (L review 150).
    /// `transcriptMissing`: a finished session's transcript is not there (its finalized marker is) and there is no progress
    /// file to rebuild it from (L review 190).
    public enum Kind: Equatable, Sendable { case transcriptWritten(URL), nothingToSalvage, finalizeFailed(String), folderNotAnswering,
                                              transcriptUnreadable(URL), transcriptMissing(URL) }
    public let kind: Kind
    public let chunkCount: Int
    /// The in-progress chunk was re-ingested but did not make it into the written transcript: its
    /// audio is on disk, untranscribed (L6 fix round 1).
    public let lastChunkKeptOnDisk: Bool
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
    /// Whether `recognitionFailures` was read: false when the written transcript could not be read back to check —
    /// then nothing is called "transcribed" (L review 149).
    public let recognitionChecked: Bool
    /// Whether the in-progress chunk is on disk could not be checked: the folder did not answer (L review 163).
    public let lastChunkUnchecked: Bool
    /// The transcript was REBUILT because the finished one could not be read back; the damaged copy is kept under this
    /// name (L review 150) — only when a look FOUND it (L review 190).
    public let rebuiltKeeping: String?
    /// Why a finished session's transcript was REBUILT (L reviews 150, 190): it was missing, or could not be read back.
    public enum Rebuilt: Equatable, Sendable { case transcriptMissing, transcriptUnreadable }
    public let rebuilt: Rebuilt?
    public init(kind: Kind, chunkCount: Int, lastChunkKeptOnDisk: Bool = false, recognitionFailures: RecognitionFailures = .init(),
                recognitionChecked: Bool = true, lastChunkUnchecked: Bool = false, rebuiltKeeping: String? = nil, rebuilt: Rebuilt? = nil) {
        // Chunks on disk are never "no recorded audio": callers report them as kept (`finalizeFailed`).
        assert(!(kind == .nothingToSalvage && chunkCount > 0), "nothingToSalvage with \(chunkCount) chunks on disk")
        self.kind = kind; self.chunkCount = chunkCount; self.lastChunkKeptOnDisk = lastChunkKeptOnDisk
        self.recognitionFailures = recognitionFailures
        self.recognitionChecked = recognitionChecked; self.lastChunkUnchecked = lastChunkUnchecked; self.rebuiltKeeping = rebuiltKeeping
        self.rebuilt = rebuilt ?? (rebuiltKeeping != nil ? .transcriptUnreadable : nil)
    }

    /// Counted from the chunks' own `asr_failed` issues. An issue with no track fails the chunk.
    public static func recognitionFailures(in chunks: [ProcessedChunk]) -> RecognitionFailures {
        tally(chunks.map { chunk in (chunk.issues.filter { $0.code == .asrFailed }.map(\.track), chunk.isDualStream) })
    }

    /// The same count from a WRITTEN transcript's `metadata.processing_issues` — what a salvage that only has
    /// the file knows (L review 93). A chunk with `mic_stream_absent` had no microphone side. Nil when the
    /// transcript cannot be read.
    public static func recognitionFailures(inTranscriptAt url: URL) -> RecognitionFailures? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = json["metadata"] as? [String: Any] else { return nil }
        var failed: [Int: [String?]] = [:]
        var withoutMic: Set<Int> = []
        for issue in metadata["processing_issues"] as? [[String: Any]] ?? [] {
            guard let chunk = issue["chunk"] as? Int, let code = issue["code"] as? String else { continue }
            if code == ChunkIssue.Code.asrFailed.rawValue { failed[chunk, default: []].append(issue["track"] as? String) }
            if code == ChunkIssue.Code.micStreamAbsent.rawValue { withoutMic.insert(chunk) }
        }
        return tally(failed.map { ($0.value, !withoutMic.contains($0.key)) })
    }

    /// Per chunk: the tracks whose recognition failed (nil = the whole chunk) and whether it had both sides.
    private static func tally(_ chunks: [(failedTracks: [String?], dualStream: Bool)]) -> RecognitionFailures {
        var result = RecognitionFailures()
        for (failed, dualStream) in chunks where !failed.isEmpty {
            let remote = failed.contains { $0 == "remote" || $0 == nil }
            let local = failed.contains { $0 == "local" || $0 == nil }
            if (remote && local) || (remote && !dualStream) { result.wholeChunks += 1 }
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
    /// vs "N chunks"/"were"/"are". Only called for a count ≥ 1 — `outcomeSentence` handles 0 itself (fix 8).
    private static func chunkPhrase(_ n: Int) -> (noun: String, wasWere: String, isAre: String) {
        n == 1 ? ("1 chunk", "was", "is") : ("\(n) chunks", "were", "are")
    }

    /// What the salvage did, as one sentence (the alerts, and the menu banners).
    public static func outcomeSentence(_ outcome: SalvageOutcome) -> String {
        switch outcome.kind {
        case .transcriptWritten(let url):
            let tail = lastChunkTail(outcome)
            if let rebuilt = outcome.rebuilt {
                // Rebuilt, never a quiet overwrite (L review 150): why — missing, or unreadable (L review 190) — the new
                // transcript's check (L review 191), and the damaged copy only when a look found it.
                let from = outcome.chunkCount > 0 ? " from its \(chunkPhrase(outcome.chunkCount).noun)" : ""
                let why = rebuilt == .transcriptMissing ? "Its transcript was missing" : "Its transcript could not be read back"
                let checked = outcome.recognitionChecked ? recognitionClauses(outcome) : "; the new one could not be read back to check them"
                let kept = outcome.rebuiltKeeping.map { "; the damaged copy is kept as \($0)" } ?? ""
                return "\(why), so it was REBUILT\(from) to \(url.lastPathComponent)\(checked)\(kept)." + tail
            }
            guard outcome.chunkCount > 0 else {
                return "No chunks were recorded, but a transcript was written to \(url.lastPathComponent)." + tail
            }
            let (noun, wasWere, _) = chunkPhrase(outcome.chunkCount)
            guard outcome.recognitionChecked else {
                // It could not be read back: nothing is claimed about its words (L review 149).
                return "The \(noun) recorded before it \(wasWere) written to \(url.lastPathComponent); it could not be read back to check them." + tail
            }
            if let allFailed = allFailed(outcome) {
                return "The \(noun) recorded before it \(wasWere) written to \(url.lastPathComponent), but \(allFailed)." + tail
            }
            return "The \(noun) recorded before it \(wasWere) transcribed to \(url.lastPathComponent)\(recognitionClauses(outcome))." + tail
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
        case .folderNotAnswering:
            return "The recording folder isn’t answering, so Parley could not check what was recorded — its audio is kept, and Parley will finish it when the folder answers."
        case .transcriptUnreadable(let url):
            // Never "could not be transcribed": it was, and its transcript is kept, only unreadable (L review 150).
            let audio = outcome.chunkCount > 0 ? " Its audio (\(chunkPhrase(outcome.chunkCount).noun)) is kept on disk." : ""
            return "Its transcript \(url.lastPathComponent) could not be read back, and no progress file was left to rebuild it from — it is kept as it is.\(audio)"
        case .transcriptMissing(let url):
            // Missing is not unreadable: nothing is "kept" of a transcript that is not there (L review 190).
            let audio = outcome.chunkCount > 0 ? " Its audio (\(chunkPhrase(outcome.chunkCount).noun)) is kept on disk." : ""
            return "Its transcript \(url.lastPathComponent) is missing, and no progress file was left to rebuild it from.\(audio)"
        }
    }

    /// The last chunk's fate, when it is not in the transcript (L6 fix round 1, L review 163).
    private static func lastChunkTail(_ outcome: SalvageOutcome) -> String {
        if outcome.lastChunkKeptOnDisk { return " The last chunk is kept on disk, not transcribed." }
        if outcome.lastChunkUnchecked { return " Parley couldn’t check the last chunk — the recording folder isn’t answering." }
        return ""
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
            let tail = lastChunkTail(outcome)
            guard outcome.recognitionChecked else {
                return "The recording stopped. The first attempt to finish its transcript failed (\(error)); Parley recovered \(what) to \(url.lastPathComponent), but could not read it back to check it." + tail
            }
            if let allFailed = allFailed(outcome) {
                return "The recording stopped. The first attempt to finish its transcript failed (\(error)); Parley recovered \(what) to \(url.lastPathComponent), but \(allFailed)." + tail
            }
            return "The recording stopped. The first attempt to finish its transcript failed (\(error)); Parley recovered and transcribed \(what) to \(url.lastPathComponent)\(recognitionClauses(outcome))." + tail
        }
        return "The recording stopped, but its transcript could not be finished\(errorClause(error, unlessIn: outcome)). " + outcomeSentence(outcome)
    }

    /// The alert title after a stop that did not end in a normal transcript. It follows the outcome: a
    /// salvaged transcript never says "Failed".
    public static func stopFailureTitle(after outcome: SalvageOutcome, stopSucceeded: Bool) -> String {
        switch outcome.kind {
        case .transcriptWritten: return "Transcript Saved After an Error"
        case .finalizeFailed, .transcriptUnreadable, .transcriptMissing: return "Transcription Failed"
        case .nothingToSalvage, .folderNotAnswering: return stopSucceeded ? "Transcription Failed" : "Stopping the Recording Failed"
        }
    }

    /// " (error)", omitted when the outcome sentence already names the same error.
    private static func errorClause(_ error: String, unlessIn outcome: SalvageOutcome) -> String {
        if case .finalizeFailed(let why) = outcome.kind, why == error { return "" }
        if outcome.kind == .folderNotAnswering { return "" }   // the sentence says it
        return " (\(error))"
    }

    /// Parley was quit (or the user logged out) while the stopped recording's transcript was being finished
    /// (L follow-up 42): a deliberate exit, not a crash.
    public static func quitWhileFinishing(outcome: SalvageOutcome) -> String {
        if case .transcriptWritten(let url) = outcome.kind, outcome.rebuilt == nil {
            let what = outcome.chunkCount > 0 ? chunkPhrase(outcome.chunkCount).noun : "the recording"
            let tail = lastChunkTail(outcome)
            guard outcome.recognitionChecked else {
                // It could not be read back: nothing is claimed about its words (L review 191).
                return "Parley was quit while finishing the transcript; it recovered \(what) to \(url.lastPathComponent), but could not read it back to check them." + tail
            }
            if let allFailed = allFailed(outcome) {
                return "Parley was quit while finishing the transcript; it recovered \(what) to \(url.lastPathComponent), but \(allFailed)." + tail
            }
            return "Parley was quit while finishing the transcript; it recovered \(what) to \(url.lastPathComponent)\(recognitionClauses(outcome))." + tail
        }
        return "Parley was quit while finishing the transcript. " + outcomeSentence(outcome)
    }

    /// A pre-0.6 single-file recording was found (L follow-up 25): kept, never "no recorded audio". Names
    /// the folder, not the meeting.
    /// `at`: when its file was last written (L review 86) — never the start; nil leaves the time out.
    public static func relaunchStoppedKeepingOlderFormat(at: Date?, folder: String) -> String {
        let when = at.map { " at \(clock($0))" } ?? ""
        return "Recording STOPPED\(when) — Parley crashed and could not resume it. An older-format recording was found and kept in \(folder)."
    }

    /// A crash with no recovery file, salvaged from the live pipeline (L review 87): says what that salvage did,
    /// never "no recovery data" next to a transcript it wrote.
    public static func crashWithoutRecoveryFile(after outcome: SalvageOutcome) -> String {
        "Recording failed — its recovery file was missing. " + outcomeSentence(outcome)
    }

    /// A crash with no recovery file AND no pipeline: nothing could be looked at, so nothing is claimed about
    /// what was recorded (L review 87).
    public static let crashWithoutRecoveryFileOrPipeline =
        "Recording failed — its recovery file was missing and no transcription was running, so Parley could not check what was recorded. Any audio it captured is in the recordings folder."

    /// A stale-boot salvage: the Mac restarted (or lost power) during the recording (R2 follow-up 1).
    /// "Parley crashed" would name the wrong cause.
    public static func relaunchStoppedByRestart(at: Date, outcome: SalvageOutcome) -> String {
        let tail = lastChunkTail(outcome)
        let cause = "Recording STOPPED at \(clock(at)) — your Mac restarted during the recording. "
        guard case .transcriptWritten(let url) = outcome.kind, outcome.chunkCount > 0, outcome.recognitionChecked, outcome.rebuilt == nil else {
            return cause + outcomeSentence(outcome)
        }
        let (noun, _, _) = chunkPhrase(outcome.chunkCount)
        if let allFailed = allFailed(outcome) {
            return cause + "Parley recovered \(noun) to \(url.lastPathComponent), but \(allFailed)." + tail
        }
        return cause + "Parley recovered \(noun) to \(url.lastPathComponent)\(recognitionClauses(outcome))." + tail
    }

    /// "speech recognition failed on it / all of them" when every chunk failed on every track.
    private static func allFailed(_ outcome: SalvageOutcome) -> String? {
        guard outcome.chunkCount > 0, outcome.recognitionFailures.wholeChunks >= outcome.chunkCount else { return nil }
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
        "Recording STOPPED at \(clock(at)) — Parley crashed and could not resume it. " + outcomeSentence(outcome)
    }

    /// A recording a relaunch salvages, worded by WHY it stopped — the cause the launch that first kept it saw, never the
    /// boot it is salvaged in (L review 147).
    public static func relaunchStopped(at: Date, outcome: SalvageOutcome, cause: RecordingSentinel.StopCause) -> String {
        switch cause {
        case .restart: return relaunchStoppedByRestart(at: at, outcome: outcome)
        case .appCrash: return relaunchStopped(at: at, outcome: outcome)
        case .captureFailed, .folderNotAnswering, .stopInterrupted, .startFailed:
            return "Recording STOPPED at \(clock(at)) — \(reason(cause)). " + outcomeSentence(outcome)
        case .userStopped:
            // The user's own Stop, whose transcript had to wait (L review 218): nothing stopped it but the user.
            return "You stopped the recording at \(clock(at)). " + outcomeSentence(outcome)
        }
    }

    /// Why a recording stopped, as a clause (L reviews 147, 186, 193, 194).
    static func reason(_ cause: RecordingSentinel.StopCause) -> String {
        switch cause {
        case .restart: return "your Mac restarted during the recording"
        case .appCrash: return "Parley crashed"
        case .captureFailed: return "its capture failed and could not be restarted"
        case .folderNotAnswering: return "the recording folder stopped answering"
        case .stopInterrupted: return "you stopped it while another stop was still under way"
        case .startFailed: return "its capture could not be started"
        case .userStopped: return "you stopped it"
        }
    }

    /// A launch's salvage was cut short by a Quit (L review 194): the cause that salvage first saw, then the quit — never
    /// "quit while finishing the transcript", which is a quit during the user's own Stop.
    public static func quitWhileRecovering(at: Date, outcome: SalvageOutcome, cause: RecordingSentinel.StopCause) -> String {
        "Recording STOPPED at \(clock(at)) — \(reason(cause)). Parley was quit while recovering it. " + outcomeSentence(outcome)
    }

    /// Audio recorded after a finished recording's transcript was written (L reviews 137, 181): how much — minutes and
    /// seconds, never rounded into a length it is not (L review 226), "less than 1 s", or "length unknown" when it could not
    /// be read — beside which transcript, and where it is kept. Nothing just stopped: no "Recording STOPPED".
    public static func audioAfterTranscript(seconds: Double?, transcript: String, folder: String) -> String {
        let length: String
        if let seconds {
            length = seconds < 1 ? "Less than 1 s of audio" : "\(duration(seconds)) of audio"
        } else {
            length = "Audio (length unknown)"
        }
        return "\(length) recorded after \(transcript) was written is kept in \(folder), not transcribed."
    }

    /// A length of at least a second, to the second (L review 226): "45 s", "2 min", "2 min 30 s".
    static func duration(_ seconds: Double) -> String {
        let total = max(1, Int(seconds.rounded()))
        guard total >= 60 else { return "\(total) s" }
        let (minutes, rest) = total.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }

    /// A session HELD because the capture helper would not let go of it, salvaged once it did (L review 177): what
    /// happened, then that Parley kept it until the helper let go, then what the salvage did — never "Parley crashed" for
    /// a capture that failed while Parley ran. A relaunch's hold is worded by why the recording stopped (`cause`).
    public static func heldStopped(at: Date, outcome: SalvageOutcome, held: RecordingSentinel.HeldReason,
                                   cause: RecordingSentinel.StopCause) -> String {
        let kept = "Parley kept it until the capture helper let go of it"
        switch held {
        case .restartFailed:
            return "Recording STOPPED at \(clock(at)) — \(reason(.captureFailed)). \(kept). " + outcomeSentence(outcome)
        case .startFailed:
            return "Recording STOPPED at \(clock(at)) — \(reason(.startFailed)). \(kept). " + outcomeSentence(outcome)
        case .stopUnderWay:
            // The user's own Stop (L review 186): nothing failed — another stop was under way, and the helper let go later.
            return "Recording STOPPED at \(clock(at)) — \(reason(.stopInterrupted)); Parley finished stopping it once the capture helper let go of it. " + outcomeSentence(outcome)
        case .relaunch:
            return "Recording STOPPED at \(clock(at)) — \(reason(cause)). \(kept). " + outcomeSentence(outcome)
        }
    }

    /// A recording kept because its folder stopped answering while its transcript was written, whose write landed once the
    /// folder answered (L review 185).
    public static func finishedOnceTheFolderAnswered(transcript: String) -> String {
        "The recording Parley kept while its folder wasn’t answering was finished once the folder answered: its transcript is \(transcript)."
    }

    /// What makes a transcription engine ready (L review 230): Setup or a model download — or, for one that cannot be made
    /// on this macOS (or that no download of Parley's makes ready), another engine chosen in Settings.
    public enum EngineRemedy: Sendable, Equatable {
        case setupOrDownload, chooseAnotherEngine
        /// The readiness look did not answer in time (L review 270): nothing is known yet — Parley checks again.
        case checkAgain
    }

    /// A salvage whose transcription engine is not ready (L review 178): nothing about the audio failed — it is kept, and
    /// transcribed once the engine is ready — and what makes it ready (L review 230).
    public static func waitingForEngine(at: Date, folder: String, why: String, remedy: EngineRemedy = .setupOrDownload) -> String {
        let kept = "A recording that stopped at \(clock(at)) is kept in \(folder), untranscribed: "
        let then = switch remedy {
        case .setupOrDownload: "Parley will transcribe it once the engine is ready — after Setup or a model download."
        case .chooseAnotherEngine: "To transcribe it, choose another engine in Settings — Parley will transcribe it then."
        case .checkAgain: "Parley will check again, and transcribe it once the engine is ready."
        }
        // Only what is known (L review 270): a look that did not answer says nothing about the engine.
        guard remedy != .checkAgain else { return kept + "Parley couldn’t check the speech model yet — it didn’t answer in time. " + then }
        return kept + "the transcription engine isn’t ready (\(why.trimmingCharacters(in: CharacterSet(charactersIn: ". ")))). " + then
    }

    /// Chunks the helper may have recorded during a rotation that timed out, which the Stop could not check because the
    /// recording folder was not answering (L review 213): said — kept on disk if they are there, not transcribed.
    public static func lateChunksUnchecked(files: [String], folder: String) -> String {
        let named = files.joined(separator: ", ")
        let one = files.count == 1
        let what = one ? "a chunk" : "\(files.count) chunks"
        let kept = one ? "If it is in \(folder), its audio is kept there" : "If they are in \(folder), their audio is kept there"
        return "Parley couldn’t check \(what) the capture helper may have recorded during a rotation that timed out (\(named)) — the recording folder wasn’t answering. \(kept), not transcribed."
    }

    /// A pending pass skipped its salvages because the capture helper's drain did not answer (L reviews 142, 201): the
    /// recordings wait — said, never silent.
    public static func waitingForHelperDrain(count: Int) -> String {
        let what = count == 1 ? "1 earlier recording" : "\(count) earlier recordings"
        return "Parley is waiting to finish \(what): the capture helper didn’t hand over its diagnostics. Their audio is kept, and Parley will try again at the next wake, mount or recording’s end."
    }

    /// Review fix 9: the wall clock can step back across a crash/resume pair; the reported gap is
    /// clamped to ≥ 0 rather than printing a negative duration.
    public static func resumedAfterCrash(crashedAt: Date, resumedAt: Date) -> String {
        let gap = max(0, Int(resumedAt.timeIntervalSince(crashedAt).rounded()))
        return "Parley crashed at \(clock(crashedAt)) and resumed at \(clock(resumedAt)) — \(gap) s not recorded."
    }
}
