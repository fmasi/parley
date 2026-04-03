import Testing
import Foundation
@testable import TranscriberCore
import FluidAudio

@Suite(.serialized) struct EngineTests {

    // MARK: - FluidAudioEngine properties

    @Test func fluidAudioEngineName() {
        let engine = FluidAudioEngine()
        #expect(engine.name == "FluidAudio")
    }

    @Test func fluidAudioEngineIsReadyReflectsCacheState() {
        let engine = FluidAudioEngine()
        // isReady() reports the actual cache state — must match isModelCached()
        #expect(engine.isReady() == FluidAudioEngine.isModelCached())
    }

    @Test func isModelCachedReturnsBool() {
        // Smoke test: must not crash and returns a sensible value.
        // In CI (no model downloaded) we expect false; on a dev machine
        // it may be true — either is valid as long as it's consistent.
        let cached = FluidAudioEngine.isModelCached()
        let engine = FluidAudioEngine()
        #expect(engine.isReady() == cached)
    }

    @Test func isModelCachedIsStable() {
        // Repeated calls must return the same value (no flaky disk check)
        let a = FluidAudioEngine.isModelCached()
        let b = FluidAudioEngine.isModelCached()
        let c = FluidAudioEngine.isModelCached()
        #expect(a == b)
        #expect(b == c)
    }

    // MARK: - FluidAudioDiarizer cache check

    @Test func isDiarizationCachedReturnsBool() {
        // Smoke test: must not crash. In CI false; on dev machine true.
        let cached = FluidAudioDiarizer.isDiarizationCached()
        // Second call must agree (stable disk check)
        #expect(cached == FluidAudioDiarizer.isDiarizationCached())
    }

    // MARK: - FluidAudioEngineError

    @Test func errorDescriptionIsActionable() {
        let error = FluidAudioEngineError.modelNotDownloaded
        let desc = error.errorDescription ?? ""
        #expect(!desc.isEmpty)
        #expect(desc.contains("Setup") || desc.contains("Settings"))
    }

    @Test func errorConformsToLocalizedError() {
        let error: any LocalizedError = FluidAudioEngineError.modelNotDownloaded
        #expect(error.errorDescription != nil)
    }

    // MARK: - Airgap guard: prepare/diarize throw when model not cached
    //
    // These tests temporarily rename the cache directory to simulate a
    // missing model, then restore it via defer. Works on dev machines
    // (models cached) and CI (nothing to rename — already missing).

    @Test func prepareThrowsWhenAsrModelNotCached() async throws {
        let cacheDir = AsrModels.defaultCacheDirectory()
        let hiddenDir = cacheDir.deletingLastPathComponent()
            .appendingPathComponent("asr-hidden-\(UUID().uuidString)")
        let fm = FileManager.default
        let wasCached = fm.fileExists(atPath: cacheDir.path)
        if wasCached {
            try? fm.removeItem(at: hiddenDir)
            try fm.moveItem(at: cacheDir, to: hiddenDir)
        }
        defer { if wasCached { try? fm.moveItem(at: hiddenDir, to: cacheDir) } }

        #expect(!FluidAudioEngine.isModelCached())
        let engine = FluidAudioEngine()
        await #expect(throws: FluidAudioEngineError.self) {
            try await engine.prepare()
        }
    }

    @Test func diarizeThrowsWhenModelNotCached() async throws {
        let baseDir = OfflineDiarizerModels.defaultModelsDirectory()
        let repoDir = baseDir.appendingPathComponent(Repo.diarizer.folderName)
        let hiddenDir = baseDir.appendingPathComponent("diar-hidden-\(UUID().uuidString)")
        let fm = FileManager.default
        let wasCached = fm.fileExists(atPath: repoDir.path)
        if wasCached {
            try? fm.removeItem(at: hiddenDir)
            try fm.moveItem(at: repoDir, to: hiddenDir)
        }
        defer { if wasCached { try? fm.moveItem(at: hiddenDir, to: repoDir) } }

        #expect(!FluidAudioDiarizer.isDiarizationCached())
        let diarizer = FluidAudioDiarizer()
        let dummyPath = URL(fileURLWithPath: "/nonexistent.wav")
        await #expect(throws: FluidAudioEngineError.self) {
            try await diarizer.diarize(audioPath: dummyPath, numSpeakers: nil)
        }
    }

    // MARK: - SpeechAnalyzerEngine properties

    #if compiler(>=6.2)
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
    #endif

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
