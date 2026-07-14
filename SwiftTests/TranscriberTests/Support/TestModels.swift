import Foundation
import Testing
@testable import TranscriberCore

/// Central policy for ML-model preconditions in tests: on CI, a missing model is a FAILURE,
/// never a silent skip.
///
/// Why so strict: the AMI diarization guard added in #136 skipped silently when models were
/// absent, so CI reported green while asserting nothing about speaker separation — the exact
/// mechanism that let a total speaker collapse ship for months. A test that can quietly decline
/// to run is not an oracle.
enum TestModels {

    /// GitHub Actions sets `CI=true` on every job.
    static var onCI: Bool { ProcessInfo.processInfo.environment["CI"] == "true" }

    /// Opt-in for tests to download models themselves (~23 MB for diarization + VAD).
    /// CI jobs set this (with a cache in front); locally it avoids pulling megabytes out
    /// from under someone running `swift test`.
    static var mayDownload: Bool { ProcessInfo.processInfo.environment["PARLEY_FETCH_MODELS"] == "1" }

    /// Make the diarization models available, downloading when allowed.
    ///
    /// Returns `true` when the models are usable. Returns `false` ONLY off-CI (a local
    /// soft-skip); on CI a missing model records a test failure before returning, so the
    /// calling test goes red instead of green-while-asserting-nothing.
    static func ensureDiarization() async throws -> Bool {
        if FluidAudioDiarizer.isDiarizationCached() { return true }
        if mayDownload {
            try await FluidAudioDiarizer.preDownloadModels()  // throws on network failure
            return FluidAudioDiarizer.isDiarizationCached()
        }
        if onCI {
            let message =
                "Diarization models are absent on CI and PARLEY_FETCH_MODELS is unset. "
                + "A silent skip here is how the speaker-collapse bug survived; set "
                + "PARLEY_FETCH_MODELS=1 in the workflow (see .github/workflows/test.yml)."
            Issue.record(Comment(rawValue: message))
        }
        return false
    }
}
