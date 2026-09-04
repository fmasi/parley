import Foundation
import Testing
@testable import TranscriberCore

/// End-to-end diarization quality guard, run against reference audio with known ground truth.
///
/// Every prior device test was a 1:1 call. Local and remote are captured on separate channels, so
/// a two-party call has exactly ONE remote speaker — remote clustering could collapse completely
/// and the transcript would still look perfect. That blind spot let `embeddingExcludeOverlap: false`
/// ship: it blended overlapping voices into every embedding, so all speakers merged into one, and
/// nothing in the suite noticed.
///
/// A multi-speaker fixture with realistic conversational overlap is the only thing that catches
/// this class of bug — measured: synthetic TTS fixtures (SyntheticDiarizationTests) cannot
/// reproduce the excludeOverlap collapse at any overlap level. Fetch the fixture with:
///     bash scripts/fetch-diarization-fixtures.sh
///
/// Skip semantics (#137, item 4 — a skip must never hide a missing assertion):
///   - The CI `test` job sets PARLEY_REQUIRE_AMI_FIXTURE=1 (it fetches the fixture first): there,
///     a missing fixture
///     or model is a test FAILURE, and `guardJobCannotSkip()` additionally proves the
///     ground-truth tests' preconditions hold, so they cannot have been silently disabled.
///   - Locally without the fixture, tests skip via `.enabled(if:)` — visible in test output,
///     and harmless because CI cannot take that path.
@Suite struct DiarizationRegressionTests {

    /// AMI ES2004a: a scenario meeting from the AMI Meeting Corpus with exactly 4 participants.
    private static var amiFixture: URL? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TranscriberTests
            .deletingLastPathComponent()   // SwiftTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("fixtures/diarization/ES2004a.Mix-Headset.wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Set by the CI `test` job, which fetches the fixture first: with it set, the
    /// ground-truth tests RUN and fail loudly on a missing fixture instead of being disabled.
    private static var fixtureRequired: Bool {
        ProcessInfo.processInfo.environment["PARLEY_REQUIRE_AMI_FIXTURE"] == "1"
    }

    private static var canRun: Bool { amiFixture != nil || fixtureRequired }

    /// Meta-test: CI must be UNABLE to skip the ground-truth assertions.
    ///
    /// Rather than counting executed tests (test ordering is not guaranteed, so a counter check
    /// can race), this asserts the preconditions that decide whether they run: with the fixture
    /// required, the fixture must exist and the models must be obtainable. If this passes, the
    /// two ground-truth tests are enabled and their `#require`s succeed — they cannot have
    /// silently no-opped. This is the test that was missing when the guard skipped in CI for
    /// months while the suite reported green.
    @Test func guardJobCannotSkip() async throws {
        guard Self.fixtureRequired else { return }  // meaningful only where the fixture is required
        #expect(Self.amiFixture != nil,
                "PARLEY_REQUIRE_AMI_FIXTURE=1 but the AMI fixture is missing — did scripts/fetch-diarization-fixtures.sh run?")
        let modelsReady = try await TestModels.ensureDiarization()
        #expect(modelsReady, "PARLEY_REQUIRE_AMI_FIXTURE=1 but diarization models are unavailable")
    }

    /// The regression that matters: 4 real speakers must not collapse into one.
    ///
    /// Measured on this exact file:
    ///   excludeOverlap = false (the shipped bug) -> 1 speaker  (639/642 embeddings in one cluster)
    ///   excludeOverlap = true  (correct default) -> 4 speakers (cluster sizes 226/170/91/51)
    @Test(.enabled(if: DiarizationRegressionTests.canRun))
    func findsMultipleSpeakersInFourSpeakerMeeting() async throws {
        let fixture = try #require(Self.amiFixture, "AMI fixture missing — run scripts/fetch-diarization-fixtures.sh")
        guard try await TestModels.ensureDiarization() else { return }

        let diarizer = FluidAudioDiarizer()   // stock config — this is the shipping default
        let result = try await diarizer.diarize(audioPath: fixture, numSpeakers: nil)

        let speakers = Set(result.segments.map(\.speaker))
        #expect(!result.segments.isEmpty, "diarizer returned no segments")

        // Ground truth is 4. Assert >= 3 rather than == 4: the point of this guard is to catch
        // catastrophic collapse, not to pin an exact DER that a model update may legitimately move.
        #expect(
            speakers.count >= 3,
            "Expected ~4 speakers in a 4-speaker meeting, got \(speakers.count). A count of 1 means speaker embeddings collapsed — check embeddingExcludeOverlap in FluidAudioDiarizer."
        )
    }

    /// Guards the specific misconfiguration that caused the collapse, so nobody reintroduces it
    /// on the theory that overlap should be included on mixed mono streams.
    @Test(.enabled(if: DiarizationRegressionTests.canRun))
    func includingOverlapInEmbeddingsCollapsesSpeakers() async throws {
        let fixture = try #require(Self.amiFixture, "AMI fixture missing — run scripts/fetch-diarization-fixtures.sh")
        guard try await TestModels.ensureDiarization() else { return }

        let broken = FluidAudioDiarizer(excludeOverlap: false)
        let brokenResult = try await broken.diarize(audioPath: fixture, numSpeakers: nil)
        let brokenCount = Set(brokenResult.segments.map(\.speaker)).count

        let correct = FluidAudioDiarizer(excludeOverlap: true)
        let correctResult = try await correct.diarize(audioPath: fixture, numSpeakers: nil)
        let correctCount = Set(correctResult.segments.map(\.speaker)).count

        // Documents the failure mode rather than merely asserting the fix: including overlap
        // strictly loses speakers, because each embedding becomes a blend of the voices present.
        #expect(
            correctCount > brokenCount,
            "excludeOverlap=true should recover speakers that excludeOverlap=false merges (got \(correctCount) vs \(brokenCount))"
        )
    }
}

/// Model-free guards that DO run in CI.
///
/// The ground-truth AMI tests above cannot run in CI: the fixture is git-ignored and the ML models
/// are not downloaded there, so both conditions are false and the suite reports green while
/// asserting nothing. Without the assertions below, reverting `excludeOverlap` to `false` — the bug
/// that collapsed every speaker into one for months — would ship with 700+ tests passing.
///
/// These take microseconds, need no models, and catch exactly that revert.
@Suite struct DiarizationDefaultsTests {

    @Test func shippingDefaultExcludesOverlap() {
        #expect(
            FluidAudioDiarizer().excludeOverlapSetting,
            "excludeOverlap MUST default to true. false blends overlapping voices into every embedding and collapses all speakers into one cluster (AMI ES2004a: 1 speaker instead of 4)."
        )
    }

    /// The config path must resolve nil to true as well — a default that only holds when constructed
    /// directly is not a default.
    ///
    /// This asserts the RESOLVED property that the runner actually consumes. Previously the runner
    /// wrote `config.diarizationExcludeOverlap ?? true` inline: a regression to `?? false` lives in
    /// the app target, which this suite cannot reach, so it would have shipped with every test green
    /// — the exact shape of the original bug. Resolution now lives in Config, where it is testable.
    @Test func configDefaultResolvesToExcludeOverlap() {
        let config = Config.default
        #expect(config.diarizationExcludeOverlap == nil, "must be unset by default")
        #expect(config.resolvedDiarizationExcludeOverlap, "an unset flag MUST resolve to true")
    }

    /// An explicit false is still honoured (it's a documented diagnostic escape hatch, and the app
    /// logs a warning) — but it must be explicit, never the default.
    @Test func explicitFalseIsHonoured() {
        var config = Config.default
        config.diarizationExcludeOverlap = false
        #expect(!config.resolvedDiarizationExcludeOverlap)
    }

    /// The wiring itself: the value Config resolves is the value the diarizer is built with. A
    /// regression anywhere along that path fails here rather than in a CI job that may be skipped.
    @Test func configResolutionReachesTheDiarizer() {
        let diarizer = FluidAudioDiarizer(
            excludeOverlap: Config.default.resolvedDiarizationExcludeOverlap
        )
        #expect(diarizer.excludeOverlapSetting)
    }
}
