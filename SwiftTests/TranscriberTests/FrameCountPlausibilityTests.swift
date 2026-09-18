import Testing
@testable import TranscriberCore

/// #196: the finalize-time backstop that compares a track's total recorded frames against how long
/// the session actually ran — catches gaps that padding itself skipped (an implausible timeline
/// delta), which `PadRatioMonitor` cannot see because it only ever judges what was actually appended.
@Suite struct FrameCountPlausibilityTests {

    private let rate = 48000.0

    /// A track that recorded (approximately) the whole session must not fire.
    @Test func matchingFramesIsHealthy() {
        let elapsed = 120.0
        let frames = Int64(elapsed * rate)
        let verdict = FrameCountPlausibility.check(
            track: "mic", framesWritten: frames, rate: rate, elapsedSeconds: elapsed
        )
        #expect(verdict == nil)
    }

    /// A small, ordinary discrepancy (a few seconds of legitimate startup skew already accounted
    /// for elsewhere) must not fire — the absolute floor exists exactly for this.
    @Test func smallDeficitDoesNotFire() {
        let elapsed = 120.0
        let frames = Int64((elapsed - 5) * rate)  // 5s short
        let verdict = FrameCountPlausibility.check(
            track: "mic", framesWritten: frames, rate: rate, elapsedSeconds: elapsed
        )
        #expect(verdict == nil)
    }

    /// A large proportional deficit that is ALSO a large absolute one fires, with the right numbers.
    @Test func largeDeficitFires() {
        let elapsed = 120.0
        let frames = Int64((elapsed - 40) * rate)  // 40s short — 33% of elapsed, well past 15s floor
        let verdict = FrameCountPlausibility.check(
            track: "system", framesWritten: frames, rate: rate, elapsedSeconds: elapsed
        )
        #expect(verdict != nil)
        #expect(verdict?.track == "system")
        #expect(verdict?.elapsedSeconds == 120.0)
        #expect(abs((verdict?.deficitSeconds ?? 0) - 40) < 0.01)
    }

    /// A session that has barely started must not be judged — mirrors `PadRatioMonitor.minimumSeconds`.
    @Test func tooEarlyIsNotJudged() {
        let elapsed = 10.0
        let frames: Int64 = 0  // nothing written yet
        let verdict = FrameCountPlausibility.check(
            track: "mic", framesWritten: frames, rate: rate, elapsedSeconds: elapsed
        )
        #expect(verdict == nil)
    }

    /// A high ratio alone (e.g. a session so short the ratio spikes) without enough ABSOLUTE
    /// deficit must not fire — both-conditions gating, same shape as `PadRatioMonitor`.
    @Test func ratioAloneWithoutAbsoluteFloorDoesNotFire() {
        let elapsed = 30.0  // right at the minimum
        let frames = Int64((elapsed - 10) * rate)  // 10s short: 33% ratio, but under the 15s floor
        let verdict = FrameCountPlausibility.check(
            track: "mic", framesWritten: frames, rate: rate, elapsedSeconds: elapsed
        )
        #expect(verdict == nil)
    }

    /// A non-positive rate must never be judged (division guard).
    @Test func nonPositiveRateNeverFires() {
        let verdict = FrameCountPlausibility.check(
            track: "mic", framesWritten: 0, rate: 0, elapsedSeconds: 120
        )
        #expect(verdict == nil)
    }
}
