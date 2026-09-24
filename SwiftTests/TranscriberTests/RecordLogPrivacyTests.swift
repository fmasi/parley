import Foundation
import Testing

/// C-M1 / R2b item 4: an error's description routinely names the file it failed on, and in Parley a
/// file name is the meeting's name (`HHmmss-Name-N.m4a`, `<meeting>.json`) and a path carries the
/// user's home folder. A `.public` interpolation puts it in the unified log in clear.
///
/// A source scan, because log privacy is invisible to a unit test. It covers EVERY
/// `TranscriberCore/*.swift`: any `.public` interpolation whose expression mentions `error`, `Error`,
/// `localizedDescription`, `path`, `url`, `URL` or `lastPathComponent`, or uses
/// `String(describing:)`, is a failure unless it is on the explicit allowlist below, with its reason.
@Suite struct RecordLogPrivacyTests {

    struct Allowed {
        let file: String
        let expression: String
        let reason: String
    }

    static let allowlist: [Allowed] = [
        // #134: provider/HTTP failures are public on purpose so they are diagnosable; the text is
        // the provider's own (or URLError's), never a path. `invalidEndpoint` is sanitized apart.
        Allowed(file: "MeetingSummarizer.swift", expression: "error.localizedDescription", reason: "#134 provider error text"),
        Allowed(file: "MeetingSummarizer.swift", expression: "error.code.rawValue", reason: "#134 URLError code"),
        // Enum values: no path, no free text.
        Allowed(file: "AppState.swift", expression: "String(describing: oldValue)", reason: "recording phase enum"),
        Allowed(file: "AppState.swift", expression: "String(describing: self.phase)", reason: "recording phase enum"),
        Allowed(file: "FluidAudioEngine.swift", expression: "String(describing: audioSource)", reason: "AudioSourceType enum"),
        Allowed(file: "PermissionManager.swift", expression: "String(describing: self.microphone)", reason: "permission status enum"),
        Allowed(file: "PermissionManager.swift", expression: "String(describing: self.screenRecording)", reason: "permission status enum"),
        Allowed(file: "PermissionManager.swift", expression: "String(describing: self.systemAudioRecording)", reason: "permission status enum"),
        Allowed(file: "PermissionManager.swift", expression: "String(describing: self.calendar)", reason: "permission status enum"),
        Allowed(file: "PermissionManager.swift", expression: "String(describing: self.notifications)", reason: "permission status enum"),
        // Other streams' files, left to them (reported in task-R2c-report.md, Round 2):
        Allowed(file: "WavFileWriter.swift", expression: "error", reason: "helper file (stream H2); already .private on cr/h2 68a21a3"),
        Allowed(file: "CaptureAlarm.swift", expression: "error", reason: "alarm registry (stream H2); an EncodingError, reported to H2"),
        Allowed(file: "RecordingCoordinator.swift", expression: "error", reason: "\"Restart failed\" (stream L); its context changed on cr/l, reported to L"),
    ]

    static let sensitiveWords = ["error", "Error", "localizedDescription", "path", "url", "URL", "lastPathComponent"]

    /// Every `\(…)` interpolation on a line, with nested parentheses.
    static func interpolations(in line: Substring) -> [Substring] {
        var result: [Substring] = []
        var index = line.startIndex
        while let open = line[index...].range(of: "\\(") {
            var depth = 0
            var cursor = line.index(before: open.upperBound)   // the "("
            var close: Substring.Index?
            while cursor < line.endIndex {
                if line[cursor] == "(" { depth += 1 }
                if line[cursor] == ")" { depth -= 1; if depth == 0 { close = cursor; break } }
                cursor = line.index(after: cursor)
            }
            guard let close else { break }
            result.append(line[open.upperBound..<close])
            index = line.index(after: close)
        }
        return result
    }

    /// The expression of a `.public` interpolation that may carry a path or an error's text; nil otherwise.
    static func leakyPublicExpression(_ body: Substring) -> String? {
        guard let marker = body.range(of: #",\s*privacy:\s*\.public\s*$"#, options: .regularExpression) else { return nil }
        let expression = body[..<marker.lowerBound].trimmingCharacters(in: .whitespaces)
        let leaky = expression.contains("String(describing:") || sensitiveWords.contains { expression.contains($0) }
        return leaky ? expression : nil
    }

    static var core: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TranscriberCore")
    }

    @Test func noCoreFileLogsAPathOrAnErrorPublicly() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.core.path).filter { $0.hasSuffix(".swift") }.sorted()
        #expect(files.count > 50, "the scan must see all of Core, not a subset")
        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: Self.core.appendingPathComponent(file), encoding: .utf8)
            for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for body in Self.interpolations(in: line) {
                    guard let expression = Self.leakyPublicExpression(body) else { continue }
                    if Self.allowlist.contains(where: { $0.file == file && $0.expression == expression }) { continue }
                    offenders.append("\(file):\(offset + 1) \(expression)")
                }
            }
        }
        #expect(offenders.isEmpty, "logged .public: \(offenders)")
    }

    /// The scanner itself: nested parentheses, and what it must and must not flag.
    @Test func theScannerFlagsWhatItShould() {
        let line: Substring = #"log("a \(type(of: error), privacy: .public) b \(url.lastPathComponent, privacy: .public) c \(count, privacy: .public) d \(error, privacy: .private)")"#
        let flagged = Self.interpolations(in: line).compactMap(Self.leakyPublicExpression)
        #expect(flagged == ["type(of: error)", "url.lastPathComponent"])
        #expect(Self.leakyPublicExpression("String(describing: x), privacy: .public") == "String(describing: x)")
    }
}
