import Testing
import Foundation
@testable import TranscriberCore

struct SpeakerSelectionTests {

    // A base tuning that carries a non-default clusteringThreshold and some
    // pre-existing speaker bounds, to verify what `applying` preserves vs. overrides.
    private func baseTuning() -> DiarizationTuning {
        DiarizationTuning(
            clusteringThreshold: 0.7,
            minSpeakers: nil,
            maxSpeakers: 4,
            exactSpeakers: nil
        )
    }

    // MARK: - .auto

    @Test func autoLeavesBaseUnchanged() {
        let base = baseTuning()
        #expect(base.applying(.auto) == base)
    }

    // MARK: - .atLeast

    @Test func atLeastSetsMinClearsExactPreservesThreshold() {
        let base = baseTuning()
        let result = base.applying(.atLeast(3))
        #expect(result.minSpeakers == 3)
        #expect(result.exactSpeakers == nil)
        #expect(result.clusteringThreshold == 0.7)
        // maxSpeakers preserved from base (floor never caps).
        #expect(result.maxSpeakers == 4)
    }

    @Test func atLeastClearsPreExistingExact() {
        let base = DiarizationTuning(exactSpeakers: 5)
        let result = base.applying(.atLeast(2))
        #expect(result.minSpeakers == 2)
        #expect(result.exactSpeakers == nil)
    }

    // MARK: - .exactly

    @Test func exactlySetsExact() {
        let base = baseTuning()
        let result = base.applying(.exactly(2))
        #expect(result.exactSpeakers == 2)
    }

    // MARK: - n < 1 handled by ignoring (treated as .auto / no-op)

    @Test func atLeastBelowOneIsIgnored() {
        let base = baseTuning()
        #expect(base.applying(.atLeast(0)) == base)
        #expect(base.applying(.atLeast(-3)) == base)
    }

    @Test func exactlyBelowOneIsIgnored() {
        let base = baseTuning()
        #expect(base.applying(.exactly(0)) == base)
        #expect(base.applying(.exactly(-1)) == base)
    }

    // MARK: - Equatable sanity

    @Test func selectionEquatable() {
        #expect(SpeakerSelection.auto == SpeakerSelection.auto)
        #expect(SpeakerSelection.atLeast(2) == SpeakerSelection.atLeast(2))
        #expect(SpeakerSelection.atLeast(2) != SpeakerSelection.exactly(2))
    }
}
