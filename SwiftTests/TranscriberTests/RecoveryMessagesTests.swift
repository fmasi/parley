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
    @Test func nothingWrittenSaysSo() {
        let m = RecoveryMessages.recordingFailed(after: SalvageOutcome(kind: .nothingToSalvage, chunkCount: 0))
        #expect(m.contains("No transcript could be written") && !m.contains("has been transcribed"))
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
}
