import Foundation

/// What a salvage actually did (§7.4 P6). The message must never claim a transcript that does not exist.
public struct SalvageOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case transcriptWritten(URL), nothingToSalvage, finalizeFailed(String) }
    public let kind: Kind
    public let chunkCount: Int
    public init(kind: Kind, chunkCount: Int) { self.kind = kind; self.chunkCount = chunkCount }
}

public enum RecoveryMessages {
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    public static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    private static func chunks(_ n: Int) -> String { n == 1 ? "1 chunk" : "\(n) chunks" }

    private static func describe(_ outcome: SalvageOutcome) -> String {
        switch outcome.kind {
        case .transcriptWritten(let url):
            return "The \(chunks(outcome.chunkCount)) recorded before it were transcribed to \(url.lastPathComponent)."
        case .nothingToSalvage:
            return "No transcript could be written: nothing had been recorded yet."
        case .finalizeFailed(let why):
            return "The \(chunks(outcome.chunkCount)) recorded before it are kept on disk but could not be transcribed: \(why)."
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

    public static func resumedAfterCrash(crashedAt: Date, resumedAt: Date) -> String {
        let gap = Int(resumedAt.timeIntervalSince(crashedAt).rounded())
        return "Parley crashed at \(clock(crashedAt)) and resumed at \(clock(resumedAt)) — \(gap) s not recorded."
    }
}
