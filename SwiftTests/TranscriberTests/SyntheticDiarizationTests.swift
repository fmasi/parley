import Foundation
import Testing
@testable import TranscriberCore

/// Diarization guard on a SYNTHESIZED multi-speaker fixture — the default oracle for CI.
///
/// The AMI ground-truth guard (DiarizationRegressionTests) is stronger, but its fixture is
/// 33 MB, git-ignored, and fetched by a script, so the plain `test` job never runs it. This
/// suite generates its fixture at test time with macOS's built-in `say` (three distinct
/// voices, zero bytes in git, no network), so speaker separation is asserted on EVERY CI run.
///
/// SCOPE — measured, not assumed: this suite is the sanity floor for clustering. It catches
/// any regression that collapses trivially-separable voices into one cluster (a broken
/// clustering threshold, a model-load failure that degrades embeddings, a dependency bump
/// that breaks clustering wholesale). It does NOT reproduce the specific
/// `embeddingExcludeOverlap: false` bug: measured on this fixture, that flag makes no
/// difference (2 speakers either way, at every overlap level tried), because the collapse
/// needs realistic conversational overlap that clean TTS audio does not have. The AMI job
/// remains the executable oracle for that bug class.
/// `.serialized`: these tests drive CoreML + `say` synthesis, which are clients of shared media XPC
/// daemons. A timed-out CI run on 2026-09-04 showed 27 such tests starting within six
/// seconds and none ever finishing — a wedged daemon blocks every client forever. Running
/// this suite's cases one at a time reduces how many are ever in flight together.
///
/// NOTE: CI currently also runs the whole suite with `--no-parallel`, because serialising
/// these suites alone cut the frozen set from 27 tests to 15 and did not stop the stall —
/// it is cross-suite. These traits are kept because they document which suites are
/// implicated, and they keep the constraint if parallelism is ever restored.
@Suite(.serialized) struct SyntheticDiarizationTests {

    @Test func threeConcatenatedVoicesYieldMultipleSpeakers() async throws {
        guard try await TestModels.ensureDiarization() else { return }

        let clips = try SyntheticSpeech.speakerClips(3)
        let mixed = try SyntheticSpeech.scratchURL("three-speakers")
        try SyntheticSpeech.concatenate(clips, to: mixed, gap: 0.5)

        let diarizer = FluidAudioDiarizer()  // stock config — the shipping default
        let result = try await diarizer.diarize(audioPath: mixed, numSpeakers: nil)

        let speakers = Set(result.segments.map(\.speaker))
        #expect(!result.segments.isEmpty, "diarizer returned no segments")
        // Ground truth is 3. Assert >= 2 rather than == 3: the oracle exists to catch
        // catastrophic collapse (1 speaker), not to pin clustering quality on TTS voices.
        let collapseMessage =
            "Expected multiple speakers in a 3-voice fixture, got \(speakers.count). "
            + "A count of 1 means clustering collapsed — check the diarizer config "
            + "(clustering threshold, embeddings) and any FluidAudio version change."
        #expect(speakers.count >= 2, Comment(rawValue: collapseMessage))
    }
}
