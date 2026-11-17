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
/// (#265). Measured in a release build (M5 Pro, 600 s of audio): a forced-count manager kept idle
/// after its pass holds about 0.9 GB, and keeping the wider pass's beside the stated count's raised
/// the peak by about 0.4 GB, while a load from the local cache takes about 135 ms. So ONE forced
/// manager is kept, and it is released BEFORE another loads: the peak is one manager, below the old
/// slot's (which released only after the next load), and a re-detect reloads rather than holds.
@Suite("Diarizer forced-count managers (#265 review)")
struct ForcedManagerSlotsTests {

    @Test("N+1 then N: the wider pass's manager is released before the stated count's loads")
    func theWiderManagerGoesBeforeTheStatedOneLoads() {
        var slots = ForcedManagerSlots()
        #expect(slots.makeRoom(for: 2) == [])
        slots.loaded(2)
        #expect(slots.makeRoom(for: 1) == [2])
        #expect(slots.held.isEmpty)
        slots.loaded(1)
        #expect(slots.held == [1])
    }

    @Test("the same count again is reused, not reloaded")
    func theSameCountIsReused() {
        var slots = ForcedManagerSlots()
        slots.loaded(1)
        slots.used(1)
        #expect(slots.held == [1])
        #expect(slots.makeRoom(for: 1) == [])
    }

    @Test("no forced manager is held while another loads, and one at most after")
    func theBoundHolds() {
        var slots = ForcedManagerSlots()
        for count in [1, 2, 3, 4, 2, 5, 5, 1, 6, 7, 3] {
            if slots.held.contains(count) {
                slots.used(count)
            } else {
                _ = slots.makeRoom(for: count)
                #expect(slots.held.isEmpty)
                slots.loaded(count)
            }
            #expect(slots.held == [count])
        }
    }
}
