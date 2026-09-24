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
    /// the type can't know — callers map "no processor" and "salvage returned nil" to
    /// `.nothingToSalvage` even when audio exists.
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

    /// C-M13: "N chunks … were transcribed to X" counted chunks whose speech recognition failed. The
    /// transcript exists, but it does not hold their words — the message says so.
    @Test func chunksWhoseRecognitionFailedAreNotCalledTranscribed() {
        let some = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 5, untranscribedChunkCount: 2))
        #expect(some.contains("The 5 chunks recorded before it were transcribed to m.json; speech recognition failed on 2 of them."))
        let all = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 3, untranscribedChunkCount: 3))
        #expect(all.contains("The 3 chunks recorded before it were written to m.json, but speech recognition failed on all of them.")
                && !all.contains("transcribed to"))
        let one = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 1, untranscribedChunkCount: 1))
        #expect(one.contains("The 1 chunk recorded before it was written to m.json, but speech recognition failed on it."))
        let clean = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .transcriptWritten(url), chunkCount: 3))
        #expect(clean.contains("The 3 chunks recorded before it were transcribed to m.json."))
    }

    /// The count comes from the session's own record: chunks with an `asr_failed` issue.
    @Test func untranscribedChunksAreCountedFromTheSession() {
        func chunk(_ i: Int, _ issues: [ChunkIssue]) -> ProcessedChunk {
            ProcessedChunk(index: i, startTime: Date(timeIntervalSince1970: 0), audioPath: "m-\(i).m4a", segments: [], speakerDatabase: [:], issues: issues)
        }
        let chunks = [chunk(0, []), chunk(1, [ChunkIssue(code: .asrFailed, track: "remote", count: nil),
                                             ChunkIssue(code: .asrFailed, track: "local", count: nil)]),
                      chunk(2, [ChunkIssue(code: .diarizationFailed, track: "remote", count: nil)]),
                      chunk(3, [ChunkIssue(code: .asrFailed, track: "local", count: nil)])]
        #expect(SalvageOutcome.untranscribedChunkCount(in: chunks) == 2)
    }
}
