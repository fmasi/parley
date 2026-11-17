import Testing
import Foundation
@testable import TranscriberCore

/// `DiarizationProvider.diarize(audioPath:numSpeakers:)` has carried a `numSpeakers` parameter
/// since the protocol was written, and `FluidAudioDiarizer` never read it — the value appeared
/// only in the function signature and the body called `mgr.process(audioPath)` regardless.
///
/// Measured on 2026-09-02 (a phone call on speakerphone, two people on one mic):
///     numSpeakers=2  ->  1 speaker   (hint discarded)
///     numSpeakers=3  ->  1 speaker   (hint discarded)
///     maxSpeakers=2  ->  2 speakers  (config knob, honoured)
///     maxSpeakers=3  ->  3 speakers
///     maxSpeakers=4  ->  4 speakers
///
/// So `maxSpeakers` behaves as a TARGET, not a ceiling — on that file the unbounded default gives
/// one speaker, and asking for N yields exactly N. That is the knob a "how many people were on this
/// recording?" control must reach, and these tests pin the plumbing that gets it there.
@Suite("Diarizer speaker count")
struct DiarizerSpeakerCountTests {

    @Test("an unforced diarizer leaves maxSpeakers at the FluidAudio default")
    func defaultConfigDoesNotPinSpeakerCount() {
        let base = FluidAudioDiarizer().makeOfflineConfig()
        let unforced = FluidAudioDiarizer().makeOfflineConfig(forcedSpeakerCount: nil)
        #expect(unforced.clustering.maxSpeakers == base.clustering.maxSpeakers)
    }

    @Test("a forced speaker count reaches clustering.maxSpeakers")
    func forcedCountReachesClusteringConfig() {
        #expect(FluidAudioDiarizer().makeOfflineConfig(forcedSpeakerCount: 2).clustering.maxSpeakers == 2)
        #expect(FluidAudioDiarizer().makeOfflineConfig(forcedSpeakerCount: 5).clustering.maxSpeakers == 5)
    }

    @Test("a forced count overrides the diarizer's configured maxSpeakers")
    func forcedCountBeatsConstructorSetting() {
        let d = FluidAudioDiarizer(maxSpeakers: 8)
        #expect(d.makeOfflineConfig(forcedSpeakerCount: 2).clustering.maxSpeakers == 2)
        #expect(d.makeOfflineConfig().clustering.maxSpeakers == 8)
    }

    @Test("a forced count does not disturb the other clustering settings")
    func forcedCountLeavesThresholdAndOverlapAlone() {
        let d = FluidAudioDiarizer(clusteringThreshold: 0.55, excludeOverlap: true)
        let forced = d.makeOfflineConfig(forcedSpeakerCount: 3)
        #expect(forced.clustering.threshold == 0.55)
        #expect(d.excludeOverlapSetting == true)
    }

    @Test("a nonsensical speaker count is ignored rather than pinning clustering to it")
    func nonPositiveCountIsIgnored() {
        let base = FluidAudioDiarizer().makeOfflineConfig()
        #expect(FluidAudioDiarizer().makeOfflineConfig(forcedSpeakerCount: 0).clustering.maxSpeakers == base.clustering.maxSpeakers)
        #expect(FluidAudioDiarizer().makeOfflineConfig(forcedSpeakerCount: -1).clustering.maxSpeakers == base.clustering.maxSpeakers)
    }
}

/// Re-detect on the mic channel asks for N+1 voices, then N when the wider pass holds no echo voice
/// (#265). With one forced-count manager kept, every such re-detect loaded both again. The two most
/// recent forced counts are kept; room is made BEFORE a load, so at most one forced manager is held
/// while another loads — the peak a one-deep slot evicting after the load already had.
@Suite("Diarizer forced-count managers (#265 review)")
struct ForcedManagerSlotsTests {

    @Test("N+1 then N, again and again: two loads, then none")
    func aRepeatedRedetectLoadsNothingTheSecondTime() {
        var slots = ForcedManagerSlots()
        #expect(slots.makeRoom(for: 2) == [])
        slots.loaded(2)
        #expect(slots.makeRoom(for: 1) == [])
        slots.loaded(1)
        // The second re-detect finds both.
        #expect(slots.held == [2, 1])
        slots.used(2)
        slots.used(1)
        #expect(slots.held == [2, 1])
    }

    @Test("a third count evicts the least recently used, before it loads")
    func aThirdCountEvictsTheOldestBeforeLoading() {
        var slots = ForcedManagerSlots()
        slots.loaded(2)
        slots.loaded(1)
        slots.used(2)
        // 1 is the least recently used: dropped before 3 loads, so only 2 is held during the load.
        #expect(slots.makeRoom(for: 3) == [1])
        #expect(slots.held == [2])
        slots.loaded(3)
        #expect(slots.held == [2, 3])
    }

    @Test("never more than one forced manager held while another loads, never more than two after")
    func theBoundHolds() {
        var slots = ForcedManagerSlots()
        for count in [1, 2, 3, 4, 2, 5, 5, 1, 6, 7, 3] {
            if slots.held.contains(count) {
                slots.used(count)
            } else {
                _ = slots.makeRoom(for: count)
                #expect(slots.held.count <= ForcedManagerSlots.capacity - 1)
                slots.loaded(count)
            }
            #expect(slots.held.count <= ForcedManagerSlots.capacity)
            #expect(slots.held.last == count)
        }
    }
}
