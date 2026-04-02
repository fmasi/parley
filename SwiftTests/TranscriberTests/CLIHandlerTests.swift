import Testing
import Foundation
@testable import TranscriberCore

struct CLIHandlerTests {

    @Test func parseTranscribeMinimal() throws {
        let args = ["AudioTranscribe", "transcribe", "-i", "system.wav"]
        let cmd = try CLIParser.parse(args)
        guard case .transcribe(let opts) = cmd else {
            Issue.record("Expected transcribe command")
            return
        }
        #expect(opts.inputs == ["system.wav"])
        #expect(opts.outputDir == nil)
        #expect(opts.format == "json")
        #expect(opts.noDiarize == false)
        #expect(opts.engine == nil)
    }

    @Test func parseTranscribeDualInput() throws {
        let args = ["AudioTranscribe", "transcribe", "-i", "system.wav", "-i", "mic.wav", "-f", "srt", "--output-dir", "/tmp/out"]
        let cmd = try CLIParser.parse(args)
        guard case .transcribe(let opts) = cmd else {
            Issue.record("Expected transcribe command")
            return
        }
        #expect(opts.inputs == ["system.wav", "mic.wav"])
        #expect(opts.outputDir == "/tmp/out")
        #expect(opts.format == "srt")
    }

    @Test func parseTranscribeAllFlags() throws {
        let args = ["AudioTranscribe", "transcribe", "-i", "a.wav", "--no-diarize", "--engine", "fluid_audio"]
        let cmd = try CLIParser.parse(args)
        guard case .transcribe(let opts) = cmd else {
            Issue.record("Expected transcribe command")
            return
        }
        #expect(opts.noDiarize == true)
        #expect(opts.engine == "fluid_audio")
    }

    @Test func parseRename() throws {
        let args = ["AudioTranscribe", "rename", "-i", "transcript.json"]
        let cmd = try CLIParser.parse(args)
        guard case .rename(let path) = cmd else {
            Issue.record("Expected rename command")
            return
        }
        #expect(path == "transcript.json")
    }

    @Test func parseBenchmark() throws {
        let args = ["AudioTranscribe", "benchmark", "--transcription-only"]
        let cmd = try CLIParser.parse(args)
        guard case .benchmark(let opts) = cmd else {
            Issue.record("Expected benchmark command")
            return
        }
        #expect(opts.transcriptionOnly == true)
        #expect(opts.diarizationOnly == false)
    }

    @Test func parseNoSubcommandReturnsNil() throws {
        let cmd = try? CLIParser.parse(["AudioTranscribe"])
        #expect(cmd == nil)
    }
}
