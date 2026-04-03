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
