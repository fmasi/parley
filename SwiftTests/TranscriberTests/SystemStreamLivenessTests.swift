import Testing
import Foundation
@testable import TranscriberCore

struct SystemStreamLivenessTests {
    // A buffer that arrived AFTER the probe started means the rebuilt stream is delivering frames.
    @Test func bufferAfterProbeStartResumes() {
        #expect(SystemStreamLiveness.framesResumed(
            lastArrivalNanos: 1_001, probeStartNanos: 1_000
        ) == true)
    }

    // No buffer since the probe started (last arrival is the pre-rebuild stamp) — not resumed.
    @Test func staleArrivalDoesNotResume() {
        #expect(SystemStreamLiveness.framesResumed(
            lastArrivalNanos: 1_000, probeStartNanos: 1_000
        ) == false)
        #expect(SystemStreamLiveness.framesResumed(
            lastArrivalNanos: 999, probeStartNanos: 1_000
        ) == false)
    }

    // A handler that never delivered a buffer keeps its initial 0 stamp — never counts as resumed.
    @Test func zeroArrivalNeverResumes() {
        #expect(SystemStreamLiveness.framesResumed(
            lastArrivalNanos: 0, probeStartNanos: 5_000_000_000
        ) == false)
    }
}
