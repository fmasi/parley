import Foundation
import Testing
@testable import TranscriberCore

/// P6: "The portion recorded before the failure has been transcribed" was said even when no
/// transcript existed and finalize had thrown.
@Suite struct RecoveryMessagesTests {
    let url = URL(fileURLWithPath: "/tmp/m.json")

    @Test func writtenTranscriptIsNamed() {
        let m = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 3))
        #expect(m.contains("m.json") && m.contains("3 chunks"))
    }
    /// Review fix 6 [Important]: the old wording ("nothing had been recorded yet") claimed a cause
    /// the type can't know. Since L6 fix round 1, callers count the chunks on disk before choosing
    /// `.nothingToSalvage`.
    @Test func nothingWrittenSaysSo() {
        let m = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0))
        #expect(m.contains("No transcript could be written: no recorded audio was found to salvage.") && !m.contains("has been transcribed"))
    }
    @Test func finalizeFailureKeepsTheAudioAndSaysWhy() {
        let m = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .finalizeFailed("disk full"), chunkCount: 2))
        #expect(m.contains("disk full") && m.contains("kept on disk"))
    }
    @Test func stopFailureCarriesTheErrorAndTheOutcome() {
        let m = RecoveryMessages.stopFailed(after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 1), error: "helper gone")
        #expect(m.contains("helper gone") && m.contains("m.json"))
    }
    // MARK: - L6 fix round 1

    /// Item 1: a failure AFTER a successful stop must not say the stop failed.
    @Test func transcriptionFailureAfterAStopSaysTheStopWorked() {
        let m = RecoveryMessages.transcriptionFailed(
            after: SalvageOutcome(kind: .finalizeFailed("disk full"), chunkCount: 1), error: "disk full")
        #expect(m.hasPrefix("The recording stopped"))
        #expect(m.contains("kept on disk") && !m.contains("Stopping the recording failed"))
    }

    /// L round 5, item 16: the finish failed, then the salvage wrote the transcript — say that, not
    /// "could not be finished … were transcribed".
    @Test func aRecoveredTranscriptAfterAFailedFinishIsWordedHonestly() {
        let m = RecoveryMessages.transcriptionFailed(
            after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 2), error: "disk busy")
        #expect(m.contains("recovered") && m.contains("2 chunks") && m.contains("m.json") && m.contains("disk busy"))
        #expect(!m.contains("could not be finished"), "\(m)")
    }

    /// Item 9: the same error is printed once, not in the lead-in AND in the outcome sentence.
    @Test func theErrorIsPrintedOnce() {
        let outcome = SalvageOutcome(kind: .finalizeFailed("helper gone"), chunkCount: 2)
        for m in [RecoveryMessages.stopFailed(after: outcome, error: "helper gone"),
                  RecoveryMessages.transcriptionFailed(after: outcome, error: "helper gone")] {
            #expect(m.components(separatedBy: "helper gone").count == 2, "\(m)")
        }
    }

    /// Item 4: the title follows the outcome; a successful salvage never says "Failed".
    @Test func stopTitlesFollowTheOutcome() {
        let written = SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 1)
        #expect(!RecoveryMessages.stopFailureTitle(after: written, stopSucceeded: false).contains("Failed"))
        #expect(RecoveryMessages.stopFailureTitle(after: SalvageOutcome(kind: .finalizeFailed("x"), chunkCount: 1), stopSucceeded: true) == "Transcription Failed")
        #expect(RecoveryMessages.stopFailureTitle(after: SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0), stopSucceeded: false) == "Stopping the Recording Failed")
        #expect(RecoveryMessages.stopFailureTitle(after: SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0), stopSucceeded: true) == "Transcription Failed")
    }

    /// Item 2: a written transcript that could not include the in-progress chunk says so.
    @Test func anUntranscribedLastChunkIsNamed() {
        let m = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 2, lastChunkKeptOnDisk: true))
        #expect(m.contains("m.json") && m.contains("last chunk") && m.contains("kept on disk"))
        #expect(!RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 2)).contains("last chunk"))
    }

    /// Item 5: the menu banners reuse the outcome sentence.
    @Test func theOutcomeSentenceIsAvailableForBanners() {
        #expect(RecoveryMessages.outcomeSentence(SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0))
                == "No transcript could be written: no recorded audio was found to salvage.")
    }

    @Test func relaunchStoppedNamesTheClockTime() {
        let at = Date(timeIntervalSince1970: 0)
        let m = RecoveryMessages.relaunchStopped(at: at, outcome: SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0))
        #expect(m.hasPrefix("Recording STOPPED at \(RecoveryMessages.clock(at))"))
    }
    @Test func resumedMessageNamesTheGap() {
        let crashed = Date(timeIntervalSince1970: 100), resumed = Date(timeIntervalSince1970: 104)
        let m = RecoveryMessages.resumedAfterCrash(crashedAt: crashed, resumedAt: resumed)
        #expect(m == "Parley crashed at \(RecoveryMessages.clock(crashed)) and resumed at \(RecoveryMessages.clock(resumed)) — 4 s not recorded.")
    }
    @Test func singularChunkGrammar() {
        let m = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 1))
        #expect(m.contains("1 chunk ") || m.contains("1 chunk)"))
    }

    // MARK: - Fix round 1

    /// Review fix 7: subject-verb agreement — a single chunk "was transcribed" / "is kept", never
    /// "were"/"are".
    @Test func singularVerbAgreement() {
        let written = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 1))
        #expect(written.contains("The 1 chunk recorded before it was transcribed to m.json."))
        let failed = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .finalizeFailed("disk full"), chunkCount: 1))
        #expect(failed.contains("The 1 chunk recorded before it is kept on disk but could not be transcribed: disk full."))
    }

    /// Review fix 8: a zero chunk count must not read "The 0 chunks …".
    @Test func zeroChunksDoesNotSayZeroChunks() {
        let written = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 0))
        #expect(!written.contains("0 chunks"))
        let failed = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .finalizeFailed("disk full"), chunkCount: 0))
        #expect(!failed.contains("0 chunks"))
    }

    /// Review fix 9: the wall clock can step back across a crash/resume pair; the reported gap is
    /// clamped to ≥ 0 rather than printing a negative duration.
    @Test func negativeGapClampsToZero() {
        let crashed = Date(timeIntervalSince1970: 104), resumed = Date(timeIntervalSince1970: 100)
        let m = RecoveryMessages.resumedAfterCrash(crashedAt: crashed, resumedAt: resumed)
        #expect(m.hasSuffix("0 s not recorded."))
    }

    /// L review 87: a crash with no recovery file never contradicts itself — when the live pipeline's salvage
    /// wrote a transcript, the banner says the file was missing, not "no recovery data available".
    @Test func aCrashWithoutItsRecoveryFileSaysWhatTheSalvageDid() {
        let written = SalvageOutcome(kind: .transcriptWritten(URL(fileURLWithPath: "/r/m.json")), chunkCount: 2)
        let banner = RecoveryMessages.crashWithoutRecoveryFile(after: written)
        #expect(banner.hasPrefix("Recording failed — its recovery file was missing."), "\(banner)")
        #expect(banner.contains("m.json") && !banner.contains("no recovery data"))
        // Nothing to look at (no recovery file, no pipeline): nothing claimed about what was recorded.
        let unknown = RecoveryMessages.crashWithoutRecoveryFileOrPipeline
        #expect(!unknown.contains("no recorded audio") && unknown.contains("recordings folder"), "\(unknown)")
    }

    /// L review 86: an older-format recording with no readable time says none.
    @Test func anOlderFormatRecordingWithoutATimeSaysNone() {
        #expect(RecoveryMessages.relaunchStoppedKeepingOlderFormat(at: nil, folder: "~/R").hasPrefix("Recording STOPPED — "))
    }

    /// C-M13 / R2b item 9: "N chunks … were transcribed to X" counted chunks whose speech recognition
    /// failed. A chunk counts as untranscribed only for the tracks that failed; one side failing is
    /// worded per side.
    @Test func chunksWhoseRecognitionFailedAreNotCalledTranscribed() {
        func outcome(_ n: Int, whole: Int = 0, remote: Int = 0, local: Int = 0) -> SalvageOutcome {
            SalvageOutcome(kind: .transcriptWritten(url), chunkCount: n,
                           recognitionFailures: .init(wholeChunks: whole, remoteOnly: remote, localOnly: local))
        }
        #expect(RecoveryMessages.recordingFailed(after: outcome(5, whole: 2))
                .contains("The 5 chunks recorded before it were transcribed to m.json; speech recognition failed on 2 of them."))
        #expect(RecoveryMessages.recordingFailed(after: outcome(3, whole: 3))
                .contains("The 3 chunks recorded before it were written to m.json, but speech recognition failed on all of them."))
        #expect(RecoveryMessages.recordingFailed(after: outcome(1, whole: 1))
                .contains("The 1 chunk recorded before it was written to m.json, but speech recognition failed on it."))
        #expect(RecoveryMessages.recordingFailed(after: outcome(4, remote: 1))
                .contains("The 4 chunks recorded before it were transcribed to m.json; the other side's speech could not be recognised in 1 of them."))
        #expect(RecoveryMessages.recordingFailed(after: outcome(4, whole: 1, local: 2))
                .contains("were transcribed to m.json; speech recognition failed on 1 of them; your microphone's speech could not be recognised in 2 of them."))
        #expect(RecoveryMessages.recordingFailed(after: outcome(3))
                .contains("The 3 chunks recorded before it were transcribed to m.json."))
    }

    /// Counted from the session's own record, per chunk and per track: a dual-stream chunk whose mic
    /// failed is not "untranscribed" — its other side was recognised.
    @Test func recognitionFailuresAreCountedPerTrack() {
        func chunk(_ i: Int, dual: Bool = true, _ tracks: [String?]) -> ProcessedChunk {
            ProcessedChunk(index: i, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-\(i).m4a", segments: [], speakerDatabase: [:],
                           isDualStream: dual, issues: tracks.map { ChunkIssue(code: .asrFailed, track: $0, count: nil) })
        }
        let chunks = [chunk(0, []), chunk(1, ["remote", "local"]), chunk(2, ["remote"]), chunk(3, ["local"]),
                      chunk(4, dual: false, ["remote"]), chunk(5, [nil]),
                      ProcessedChunk(index: 6, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-6.m4a", segments: [], speakerDatabase: [:],
                                     isDualStream: true, issues: [ChunkIssue(code: .diarizationFailed, track: "remote", count: nil)])]
        #expect(SalvageOutcome.recognitionFailures(in: chunks) == .init(wholeChunks: 3, remoteOnly: 1, localOnly: 1))
    }

    /// R2 follow-up 1: a stale-boot salvage (the Mac rebooted or lost power mid-recording) said
    /// "Parley crashed and could not resume it" — the wrong cause. It names the restart instead.
    @Test func aStaleBootSalvageNamesTheRestartNotACrash() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let clock = RecoveryMessages.clock(at)
        let written = RecoveryMessages.relaunchStoppedByRestart(at: at, outcome: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 3))
        #expect(written == "Recording STOPPED at \(clock) — your Mac restarted during the recording. Parley recovered 3 chunks to m.json.")
        #expect(!written.contains("crashed"))
        let one = RecoveryMessages.relaunchStoppedByRestart(at: at, outcome: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 1, recognitionFailures: .init(wholeChunks: 1)))
        #expect(one.hasSuffix("your Mac restarted during the recording. Parley recovered 1 chunk to m.json, but speech recognition failed on it."))
        let some = RecoveryMessages.relaunchStoppedByRestart(at: at, outcome: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 4, recognitionFailures: .init(wholeChunks: 1)))
        #expect(some.hasSuffix("Parley recovered 4 chunks to m.json; speech recognition failed on 1 of them."))
        let kept = RecoveryMessages.relaunchStoppedByRestart(at: at, outcome: SalvageOutcome(kind: .finalizeFailed("disk full"), chunkCount: 2))
        #expect(kept == "Recording STOPPED at \(clock) — your Mac restarted during the recording. The 2 chunks recorded before it are kept on disk but could not be transcribed: disk full.")
        let nothing = RecoveryMessages.relaunchStoppedByRestart(at: at, outcome: SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0))
        #expect(nothing.hasSuffix("your Mac restarted during the recording. No transcript could be written: no recorded audio was found to salvage."))
    }

    // MARK: - L round C (149, 150, 156, 163)

    /// L review 156: the merge's untested branches. A written transcript after a failed finish, or a quit, honours the
    /// recognition failures: all of them, or some.
    @Test func aFailedFinishAndAQuitHonourRecognitionFailures() {
        let all = SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 2, recognitionFailures: .init(wholeChunks: 2))
        let some = SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 3, recognitionFailures: .init(remoteOnly: 1, localOnly: 1))
        #expect(RecoveryMessages.transcriptionFailed(after: all, error: "e").hasSuffix("Parley recovered the 2 chunks to m.json, but speech recognition failed on all of them."))
        #expect(RecoveryMessages.transcriptionFailed(after: some, error: "e").hasSuffix(
            "recovered and transcribed the 3 chunks to m.json; the other side's speech could not be recognised in 1 of them; your microphone's speech could not be recognised in 1 of them."))
        #expect(RecoveryMessages.quitWhileFinishing(outcome: all) == "Parley was quit while finishing the transcript; it recovered 2 chunks to m.json, but speech recognition failed on all of them.")
        #expect(RecoveryMessages.quitWhileFinishing(outcome: some).hasSuffix("it recovered 3 chunks to m.json; the other side's speech could not be recognised in 1 of them; your microphone's speech could not be recognised in 1 of them."))
    }

    /// L review 156: a restart's salvage keeps the last-chunk tail; "all failed" never fires for no chunks at all.
    @Test func aRestartKeepsTheLastChunkTailAndNoChunksNeverAllFail() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let tail = RecoveryMessages.relaunchStoppedByRestart(at: at, outcome: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 2, lastChunkKeptOnDisk: true))
        #expect(tail.hasSuffix("Parley recovered 2 chunks to m.json. The last chunk is kept on disk, not transcribed."))
        let none = RecoveryMessages.outcomeSentence(SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 0, recognitionFailures: .init(wholeChunks: 1)))
        #expect(none == "No chunks were recorded, but a transcript was written to m.json.", "never \"failed on all of them\"")
    }

    /// L review 156: a chunk with `mic_stream_absent` had no microphone side — its remote failure is the whole chunk.
    @Test func aChunkWithoutAMicrophoneFailsWhole() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("messages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.json")
        let json: [String: Any] = ["metadata": ["processing_issues": [
            ["chunk": 0, "code": ChunkIssue.Code.asrFailed.rawValue, "track": "remote"],
            ["chunk": 0, "code": ChunkIssue.Code.micStreamAbsent.rawValue],
            ["chunk": 1, "code": ChunkIssue.Code.asrFailed.rawValue, "track": "remote"],
        ]]]
        try JSONSerialization.data(withJSONObject: json).write(to: transcript)
        #expect(SalvageOutcome.recognitionFailures(inTranscriptAt: transcript) == .init(wholeChunks: 1, remoteOnly: 1))
    }

    /// L review 149: a transcript that could not be read back is never called "transcribed".
    @Test func anUncheckedTranscriptIsNeverCalledTranscribed() {
        let unchecked = SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 2, recognitionChecked: false)
        #expect(RecoveryMessages.outcomeSentence(unchecked) == "The 2 chunks recorded before it were written to m.json; it could not be read back to check them.")
        #expect(!RecoveryMessages.transcriptionFailed(after: unchecked, error: "e").contains("transcribed"))
        #expect(!RecoveryMessages.relaunchStoppedByRestart(at: Date(), outcome: unchecked).contains("transcribed"))
    }

    /// L review 150: a rebuild says it was REBUILT and names the damaged copy; an unreadable transcript with nothing to
    /// rebuild from is never "could not be transcribed".
    @Test func aRebuildAndAnUnreadableTranscriptAreSaidForWhatTheyAre() {
        let rebuilt = SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 2, rebuiltKeeping: "m.damaged.json")
        #expect(RecoveryMessages.outcomeSentence(rebuilt) == "Its transcript could not be read back, so it was REBUILT from its 2 chunks to m.json; the damaged copy is kept as m.damaged.json.")
        #expect(RecoveryMessages.relaunchStoppedByRestart(at: Date(), outcome: rebuilt).contains("REBUILT"))
        #expect(RecoveryMessages.quitWhileFinishing(outcome: rebuilt).contains("REBUILT"))
        let unreadable = SalvageOutcome(kind: .transcriptUnreadable(url), chunkCount: 1)
        #expect(RecoveryMessages.outcomeSentence(unreadable) == "Its transcript m.json could not be read back, and no progress file was left to rebuild it from — it is kept as it is. Its audio (1 chunk) is kept on disk.")
        #expect(RecoveryMessages.stopFailureTitle(after: unreadable, stopSucceeded: true) == "Transcription Failed")
    }

    /// L review 163: a last chunk the folder did not show is said as unchecked — never silence.
    @Test func anUncheckedLastChunkIsSaid() {
        let outcome = SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 1, lastChunkUnchecked: true)
        #expect(RecoveryMessages.outcomeSentence(outcome).hasSuffix("Parley couldn’t check the last chunk — the recording folder isn’t answering."))
    }
}
