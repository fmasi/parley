import Testing
import Foundation
@testable import TranscriberCore

struct EngineTests {

    // MARK: - FluidAudioEngine properties

    @Test func fluidAudioEngineName() {
        let engine = FluidAudioEngine()
        #expect(engine.name == "FluidAudio")
    }

    @Test func fluidAudioEngineIsAlwaysReady() {
        let engine = FluidAudioEngine()
        #expect(engine.isReady() == true)
    }

    // MARK: - SpeechAnalyzerEngine properties

    @Test func speechAnalyzerEngineName() {
        if #available(macOS 26.0, *) {
            let engine = SpeechAnalyzerEngine()
            #expect(engine.name == "SpeechAnalyzer")
        }
    }

    @Test func speechAnalyzerEngineIsAlwaysReady() {
        if #available(macOS 26.0, *) {
            let engine = SpeechAnalyzerEngine()
            #expect(engine.isReady() == true)
        }
    }

    // MARK: - WhisperCppEngine properties

    @Test func whisperCppEngineName() {
        let engine = WhisperCppEngine(modelPath: URL(fileURLWithPath: "/tmp/nonexistent.bin"))
        #expect(engine.name == "WhisperCpp")
    }

    @Test func whisperCppEngineIsReadyReturnsFalseForMissingModel() {
        let engine = WhisperCppEngine(modelPath: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID()).bin"))
        #expect(engine.isReady() == false)
    }

    @Test func whisperCppEngineIsReadyReturnsTrueForExistingFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-model-\(UUID()).bin")
        FileManager.default.createFile(atPath: tmp.path, contents: Data("fake".utf8))
        defer { try? FileManager.default.removeItem(at: tmp) }

        let engine = WhisperCppEngine(modelPath: tmp)
        #expect(engine.isReady() == true)
    }

    // MARK: - Token grouping (FluidAudioEngine pure logic)

    @Test func groupTokensEmptyInput() {
        let result = FluidAudioEngine.groupTokensIntoSegments([], language: "en")
        #expect(result.isEmpty)
    }

    @Test func groupTokensSingleSentence() {
        let timings = [
            TokenTiming(startTime: 0.0, endTime: 0.5, token: "Hello"),
            TokenTiming(startTime: 0.5, endTime: 1.0, token: " world"),
            TokenTiming(startTime: 1.0, endTime: 1.5, token: "."),
        ]
        let result = FluidAudioEngine.groupTokensIntoSegments(timings, language: "en")
        #expect(result.count == 1)
        #expect(result[0].text == "Hello world.")
        #expect(result[0].start == 0.0)
        #expect(result[0].end == 1.5)
        #expect(result[0].language == "en")
    }

    @Test func groupTokensMultipleSentences() {
        let timings = [
            TokenTiming(startTime: 0.0, endTime: 0.5, token: "Hi"),
            TokenTiming(startTime: 0.5, endTime: 1.0, token: "."),
            TokenTiming(startTime: 1.0, endTime: 1.5, token: " Bye"),
            TokenTiming(startTime: 1.5, endTime: 2.0, token: "!"),
        ]
        let result = FluidAudioEngine.groupTokensIntoSegments(timings, language: nil)
        #expect(result.count == 2)
        #expect(result[0].text == "Hi.")
        #expect(result[0].start == 0.0)
        #expect(result[0].end == 1.0)
        #expect(result[1].text == "Bye!")
        #expect(result[1].start == 1.0)
        #expect(result[1].end == 2.0)
    }

    @Test func groupTokensTrailingTextWithoutPunctuation() {
        let timings = [
            TokenTiming(startTime: 0.0, endTime: 0.5, token: "Hello"),
            TokenTiming(startTime: 0.5, endTime: 1.0, token: " world"),
        ]
        let result = FluidAudioEngine.groupTokensIntoSegments(timings, language: "pt")
        #expect(result.count == 1)
        #expect(result[0].text == "Hello world")
        #expect(result[0].language == "pt")
    }

    @Test func groupTokensSkipsWhitespaceOnlyTrailing() {
        // Trailing whitespace-only tokens produce no segment (trimmed to empty)
        let timings = [
            TokenTiming(startTime: 0.0, endTime: 0.5, token: "Hi"),
            TokenTiming(startTime: 0.5, endTime: 1.0, token: "."),
            TokenTiming(startTime: 1.0, endTime: 1.5, token: " "),
        ]
        let result = FluidAudioEngine.groupTokensIntoSegments(timings, language: nil)
        #expect(result.count == 1)
        #expect(result[0].text == "Hi.")
    }

    @Test func groupTokensQuestionMark() {
        let timings = [
            TokenTiming(startTime: 0.0, endTime: 0.5, token: "Really"),
            TokenTiming(startTime: 0.5, endTime: 1.0, token: "?"),
        ]
        let result = FluidAudioEngine.groupTokensIntoSegments(timings, language: nil)
        #expect(result.count == 1)
        #expect(result[0].text == "Really?")
    }

    @Test func groupTokensNilLanguagePropagated() {
        let timings = [
            TokenTiming(startTime: 0.0, endTime: 0.5, token: "Test"),
        ]
        let result = FluidAudioEngine.groupTokensIntoSegments(timings, language: nil)
        #expect(result[0].language == nil)
    }

    @Test func groupTokensDecimalPointDoesNotSplit() {
        let timings = [
            TokenTiming(startTime: 0.0, endTime: 0.5, token: "The budget was"),
            TokenTiming(startTime: 0.5, endTime: 1.0, token: " 1."),
            TokenTiming(startTime: 1.0, endTime: 1.5, token: "5 million dollars."),
        ]
        let result = FluidAudioEngine.groupTokensIntoSegments(timings, language: "en")
        #expect(result.count == 1)
        #expect(result[0].text == "The budget was 1.5 million dollars.")
    }

    @Test func groupTokensRegularPeriodStillSplits() {
        let timings = [
            TokenTiming(startTime: 0.0, endTime: 0.5, token: "Hello."),
            TokenTiming(startTime: 0.5, endTime: 1.0, token: " Goodbye."),
        ]
        let result = FluidAudioEngine.groupTokensIntoSegments(timings, language: "en")
        #expect(result.count == 2)
        #expect(result[0].text == "Hello.")
        #expect(result[1].text == "Goodbye.")
    }
}
