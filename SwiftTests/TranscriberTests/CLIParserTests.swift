import Testing
import Foundation
@testable import TranscriberCore

struct CLIParserTests {

    /// The app enters CLI mode for exactly `CLIParser.subcommands` (#299): every listed name must
    /// parse, and `benchmark` (no parser case) must not be listed.
    @Test func everyListedSubcommandIsAcceptedByTheParser() {
        #expect(!CLIParser.subcommands.contains("benchmark"))
        for name in CLIParser.subcommands {
            do {
                _ = try CLIParser.parse(["Parley", name])
            } catch CLIParser.ParseError.unknownSubcommand(let cmd) {
                Issue.record("listed subcommand \(cmd) is rejected by the parser")
            } catch {
                // Missing arguments are fine: the name itself was recognised.
            }
        }
        #expect(throws: CLIParser.ParseError.self) {
            try CLIParser.parse(["Parley", "benchmark"])
        }
    }

    @Test func parsesSummarizeWithInput() throws {
        let cmd = try CLIParser.parse(["Parley", "summarize", "-i", "/tmp/meeting.json"])
        guard case .summarize(let opts) = cmd else {
            Issue.record("Expected .summarize, got \(String(describing: cmd))")
            return
        }
        #expect(opts.input == "/tmp/meeting.json")
        #expect(opts.endpoint == nil)
        #expect(opts.apiKey == nil)
        #expect(opts.model == nil)
    }

    @Test func parsesSummarizeWithAllFlags() throws {
        let cmd = try CLIParser.parse([
            "Parley", "summarize",
            "-i", "/tmp/meeting.json",
            "--endpoint", "http://localhost:11434/v1",
            "--api-key", "sk-test",
            "--model", "llama3"
        ])
        guard case .summarize(let opts) = cmd else {
            Issue.record("Expected .summarize")
            return
        }
        #expect(opts.input == "/tmp/meeting.json")
        #expect(opts.endpoint == "http://localhost:11434/v1")
        #expect(opts.apiKey == "sk-test")
        #expect(opts.model == "llama3")
    }

    @Test func summarizeMissingInputThrows() {
        #expect(throws: CLIParser.ParseError.self) {
            try CLIParser.parse(["Parley", "summarize"])
        }
    }

    // MARK: - --debug flag

    @Test func parsesDebugFlag() throws {
        let cmd = try CLIParser.parse(["Parley", "transcribe", "-i", "test.wav", "--debug"])
        guard case .transcribe(let opts) = cmd else {
            Issue.record("Expected .transcribe, got \(String(describing: cmd))")
            return
        }
        #expect(opts.debug == true)
    }

    @Test func defaultsFlagsToFalse() throws {
        let cmd = try CLIParser.parse(["Parley", "transcribe", "-i", "test.wav"])
        guard case .transcribe(let opts) = cmd else {
            Issue.record("Expected .transcribe, got \(String(describing: cmd))")
            return
        }
        #expect(opts.debug == false)
        #expect(opts.splitMode == .ask)
    }

    // MARK: - --split and --no-split flags

    @Test func parsesSplitFlag() throws {
        let cmd = try CLIParser.parse(["Parley", "transcribe", "-i", "test.m4a", "--split"])
        guard case .transcribe(let opts) = cmd else {
            Issue.record("Expected .transcribe, got \(String(describing: cmd))")
            return
        }
        #expect(opts.splitMode == .split)
    }

    @Test func parsesNoSplitFlag() throws {
        let cmd = try CLIParser.parse(["Parley", "transcribe", "-i", "test.m4a", "--no-split"])
        guard case .transcribe(let opts) = cmd else {
            Issue.record("Expected .transcribe, got \(String(describing: cmd))")
            return
        }
        #expect(opts.splitMode == .noSplit)
    }

    @Test func defaultsSplitModeToAsk() throws {
        let cmd = try CLIParser.parse(["Parley", "transcribe", "-i", "test.m4a"])
        guard case .transcribe(let opts) = cmd else {
            Issue.record("Expected .transcribe, got \(String(describing: cmd))")
            return
        }
        #expect(opts.splitMode == .ask)
    }

    @Test func conflictingSplitFlagsThrows() {
        #expect(throws: CLIParser.ParseError.self) {
            try CLIParser.parse(["Parley", "transcribe", "-i", "test.m4a", "--split", "--no-split"])
        }
    }
}
