import Foundation
import Testing

/// C-M1 (R2 council, item 9): an error's description routinely names the file it failed on, and on
/// the record side a file name is the meeting's name (`HHmmss-Name-N.m4a`). `.public` error
/// interpolations put it in the unified log in clear. The record files log an error `.private`,
/// with its type `.public` when the kind is worth reading.
///
/// A source scan, because log privacy is invisible to a unit test. Out of scope here:
/// `MeetingSummarizer` (its provider errors are public on purpose, #134, and carry no path) and the
/// app/helper targets (other streams).
@Suite struct RecordLogPrivacyTests {
    static let recordFiles = [
        "ChunkSession", "ChunkProcessor", "ChunkRotator", "TranscriptionRunner", "TranscriptAssembler",
        "AudioArchiver", "AudioConcatenator", "TranscriptRediarizer", "CrashRecoveryPlanner",
        "ChunkedSessionRecovery", "TokenRatioCache", "CaptureDiagnostics", "TrackAccounting", "RecoveryMessages",
    ]

    @Test func noRecordFileLogsAnErrorPublicly() throws {
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TranscriberCore")
        let publicError = try Regex(#"\\\(error(\.localizedDescription)?, privacy: \.public\)"#)
        for name in Self.recordFiles {
            let source = try String(contentsOf: core.appendingPathComponent("\(name).swift"), encoding: .utf8)
            let offenders = source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .filter { $0.element.contains(publicError) }
                .map { "\(name).swift:\($0.offset + 1)" }
            #expect(offenders.isEmpty, "error logged .public: \(offenders)")
        }
    }
}
