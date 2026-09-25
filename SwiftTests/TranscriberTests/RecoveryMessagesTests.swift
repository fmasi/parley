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
}
