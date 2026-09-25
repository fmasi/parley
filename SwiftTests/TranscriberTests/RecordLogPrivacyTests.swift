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

    /// One allowed source LINE (trimmed, exact): an allowlisted file gets no pass for any other line
    /// (R2 round 3 item 7). Entries for other streams' sites go when those streams fix them.
    struct Allowed {
        let file: String
        let line: String
        let reason: String
    }

    static let allowlist: [Allowed] = [
        // #134: provider/HTTP failures are public on purpose so they are diagnosable; the text is
        // the provider's own (or URLError's), never a path. `invalidEndpoint` is sanitized apart.
        Allowed(file: "MeetingSummarizer.swift",
                line: #"Logger.transcription.error("Summary generation failed: \(error.localizedDescription, privacy: .public)")"#,
                reason: "#134 provider error text"),
        Allowed(file: "MeetingSummarizer.swift",
                line: #""Summary generation failed: \(error.code.rawValue, privacy: .public) \(error.localizedDescription, privacy: .public)""#,
                reason: "#134 URLError code and text"),
        // Enum values: no path, no free text.
        Allowed(file: "AppState.swift",
                line: #"Logger.state.info("State: \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.phase), privacy: .public)")"#,
                reason: "recording phase enum"),
        Allowed(file: "RecordingCoordinator.swift",
                line: #"Logger.state.info("Relaunch decision: \(String(describing: decision), privacy: .public)")"#,
                reason: "RelaunchDecision enum: cases, a date and a duration, never a path or a name"),
        Allowed(file: "FluidAudioEngine.swift",
                line: #"Logger.transcription.info("Transcribing: \(audioPath.lastPathComponent, privacy: .sensitive) with FluidAudio (source: \(String(describing: audioSource), privacy: .public))")"#,
                reason: "AudioSourceType enum"),
        Allowed(file: "PermissionManager.swift",
                line: #"Logger.permissions.info("Permissions — mic: \(String(describing: self.microphone), privacy: .public), screen: \(String(describing: self.screenRecording), privacy: .public), system audio: \(String(describing: self.systemAudioRecording), privacy: .public) (source \(self.systemAudioSource.rawValue, privacy: .public)), calendar: \(String(describing: self.calendar), privacy: .public), notifications: \(String(describing: self.notifications), privacy: .public)")"#,
                reason: "permission status enums"),
        Allowed(file: "PermissionManager.swift", line: #"Logger.permissions.debug("Microphone permission: \(String(describing: self.microphone), privacy: .public)")"#, reason: "permission status enum"),
        Allowed(file: "PermissionManager.swift", line: #"Logger.permissions.debug("Screen recording permission: \(String(describing: self.screenRecording), privacy: .public)")"#, reason: "permission status enum"),
        Allowed(file: "PermissionManager.swift", line: #"Logger.permissions.info("System Audio Recording permission: \(String(describing: self.systemAudioRecording), privacy: .public)")"#, reason: "permission status enum"),
        Allowed(file: "PermissionManager.swift", line: #"Logger.permissions.debug("Calendar permission: \(String(describing: self.calendar), privacy: .public)")"#, reason: "permission status enum"),
        Allowed(file: "PermissionManager.swift", line: #"Logger.permissions.debug("Notifications permission: \(String(describing: self.notifications), privacy: .public)")"#, reason: "permission status enum"),
        // Other streams' sites, left to them (task-R2c-report.md, Round 2):
        Allowed(file: "WavFileWriter.swift",
                line: #"Logger.files.error("WAV write failure (\(context, privacy: .public)): \(self.path, privacy: .sensitive): \(error, privacy: .public)")"#,
                reason: "helper file (stream H2); already .private on cr/h2 68a21a3"),
        Allowed(file: "WavFileWriter.swift", line: #"Logger.files.error("WAV seekToEnd after header flush failed: \(error, privacy: .public)")"#,
                reason: "helper file (stream H2); already .private on cr/h2 68a21a3"),
        Allowed(file: "WavFileWriter.swift", line: #"Logger.files.error("WAV header repair failed: \(path, privacy: .sensitive): \(error, privacy: .public)")"#,
                reason: "helper file (stream H2); already .private on cr/h2 68a21a3"),
        Allowed(file: "CaptureAlarm.swift", line: #"Logger.audio.error("Capture status snapshot could not be encoded: \(error, privacy: .public)")"#,
                reason: "alarm registry (stream H2); an EncodingError, reported to H2"),
        // App sources (L review 95): enum values, no path, no free text.
        Allowed(file: "AppTerminationDelegate.swift",
                line: #"Logger.state.info("Termination (\(String(describing: kind), privacy: .public)) with work in flight — stopping the helper first, bounded")"#,
                reason: "TerminationPolicy.Kind enum"),
        Allowed(file: "AudioCaptureClient.swift", line: #"Logger.audio.debug("XPC status ping: \(String(describing: state), privacy: .public)")"#,
                reason: "HelperCaptureState enum"),
    ]

    static func isAllowed(file: String, line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return allowlist.contains { $0.file == file && $0.line == trimmed }
    }

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
                    if Self.isAllowed(file: file, line: line) { continue }
                    offenders.append("\(file):\(offset + 1) \(expression)")
                }
            }
        }
        #expect(offenders.isEmpty, "logged .public: \(offenders)")
    }

    static var app: URL { core.deletingLastPathComponent().appendingPathComponent("TranscriberApp") }

    /// L review 95: the app target's sources follow the same rule — its XPC client logs the helper's errors,
    /// which name the recording's files. A source scan too (the test target cannot import the app).
    @Test func noAppFileLogsAPathOrAnErrorPublicly() throws {
        let enumerator = try #require(FileManager.default.enumerator(atPath: Self.app.path))
        let files = enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.sorted()
        #expect(files.count > 20, "the scan must see all of the app, not a subset")
        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: Self.app.appendingPathComponent(file), encoding: .utf8)
            let name = URL(fileURLWithPath: file).lastPathComponent
            for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for body in Self.interpolations(in: line) {
                    guard let expression = Self.leakyPublicExpression(body) else { continue }
                    if Self.isAllowed(file: name, line: line) { continue }
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

    /// Round 3 item 7: an allowlisted file gets no pass for a NEW line — only the exact lines listed.
    @Test func anAllowlistedFileGetsNoPassForANewLine() {
        #expect(Self.isAllowed(file: "WavFileWriter.swift",
                               line: #"            Logger.files.error("WAV seekToEnd after header flush failed: \(error, privacy: .public)")"#))
        #expect(!Self.isAllowed(file: "WavFileWriter.swift", line: #"Logger.files.error("Something new: \(error, privacy: .public)")"#))
        #expect(!Self.isAllowed(file: "ChunkProcessor.swift",
                                line: #"Logger.files.error("WAV seekToEnd after header flush failed: \(error, privacy: .public)")"#))
    }
}
