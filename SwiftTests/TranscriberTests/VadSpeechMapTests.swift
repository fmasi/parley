import Testing
import Foundation
@testable import TranscriberCore

struct VadSpeechMapTests {

    // MARK: - speechOverlap

    @Test func fullOverlapReturnsOne() {
        let regions = [SpeechRegion(start: 0.0, end: 10.0, probability: 0.95)]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 2.0, end: 5.0, threshold: 0.5)
        #expect(result == 1.0)
    }

    @Test func noOverlapReturnsZero() {
        let regions = [SpeechRegion(start: 0.0, end: 2.0, probability: 0.95)]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 5.0, end: 8.0, threshold: 0.5)
        #expect(result == 0.0)
    }

    @Test func partialOverlapReturnsProportionalValue() {
        let regions = [SpeechRegion(start: 0.0, end: 3.0, probability: 0.95)]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 2.0, end: 6.0, threshold: 0.5)
        // 1s overlap out of 4s segment = 0.25
        #expect(abs(result - 0.25) < 0.001)
    }

    @Test func multipleRegionsSpanningOneSegment() {
        let regions = [
            SpeechRegion(start: 0.0, end: 2.0, probability: 0.9),
            SpeechRegion(start: 4.0, end: 6.0, probability: 0.9),
        ]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 0.0, end: 8.0, threshold: 0.5)
        // 4s overlap out of 8s segment = 0.5
        #expect(abs(result - 0.5) < 0.001)
    }

    @Test func emptyRegionsReturnsZero() {
        let result = SpeechRegion.speechOverlap(regions: [], start: 0.0, end: 5.0, threshold: 0.5)
        #expect(result == 0.0)
    }

    @Test func zeroDurationSegmentReturnsZero() {
        let regions = [SpeechRegion(start: 0.0, end: 10.0, probability: 0.95)]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 5.0, end: 5.0, threshold: 0.5)
        #expect(result == 0.0)
    }

    @Test func regionBelowThresholdIsIgnored() {
        let regions = [SpeechRegion(start: 0.0, end: 10.0, probability: 0.3)]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 2.0, end: 5.0, threshold: 0.5)
        #expect(result == 0.0)
    }

    @Test func mixedProbabilityRegions() {
        let regions = [
            SpeechRegion(start: 0.0, end: 5.0, probability: 0.9),  // above threshold
            SpeechRegion(start: 5.0, end: 10.0, probability: 0.2), // below threshold
        ]
        let result = SpeechRegion.speechOverlap(regions: regions, start: 0.0, end: 10.0, threshold: 0.5)
        // 5s overlap out of 10s segment = 0.5
        #expect(abs(result - 0.5) < 0.001)
    }
}

/// `analyze(samples:)` (#204): lets a caller that already decoded the audio for another consumer
/// (the diarizer, in `TranscriptRediarizer`) share that buffer instead of handing `analyze` a path
/// and paying for a second decode of identical audio.
@Suite("VadSpeechMap analyze(samples:)")
struct VadSpeechMapAnalyzeSamplesTests {

    /// CI (and most dev machines running this suite) has no cached VAD model, so this exercises
    /// the real graceful-degradation branch shared with `analyze(audioPath:)` — not a stub. If a
    /// machine DOES have the model cached, there is nothing to assert here (VAD would actually
    /// run), so the test is a no-op rather than a false failure.
    @Test("returns nil when the VAD model is not cached, matching analyze(audioPath:)")
    func returnsNilWhenModelNotCached() async throws {
        guard !VadSpeechMap.isModelCached() else { return }
        let samples = [Float](repeating: 0, count: 1600)
        let result = try await VadSpeechMap().analyze(samples: samples)
        #expect(result == nil)
    }
}
