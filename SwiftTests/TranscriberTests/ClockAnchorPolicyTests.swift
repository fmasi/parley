import Testing
@testable import TranscriberCore

/// Which device should CLOCK the capture aggregate.
///
/// Regression cover for the 2026-08-04 recording: AirPods connected mid-meeting, the output-change
/// rebuild read their rate as 48 kHz (still A2DP), so the aggregate was clocked off the AirPods —
/// and macOS flipped them to 24 kHz HFP moments later, because our own mic capture opened on the
/// same device. A2DP → HFP is not a device change, so nothing rebuilt: 22 minutes of remote audio
/// were written at half rate under a 48 kHz header (chipmunk), silence-padded to hold the wall clock.
@Suite struct ClockAnchorPolicyTests {

    // MARK: - Healthy outputs must be left alone

    @Test func healthyWiredOutputKeepsItsOwnClock() {
        #expect(ClockAnchorPolicy.decide(outputRate: 48000, isBluetooth: false, forcedByDrift: false)
                == .keepOutput)
    }

    /// 44.1 kHz is a perfectly healthy rate. Substituting the clock for a device that is fine is a
    /// risk with no upside — this guard is deliberate, not an oversight.
    @Test func fortyFourOneIsHealthyNotDegraded() {
        #expect(ClockAnchorPolicy.decide(outputRate: 44100, isBluetooth: false, forcedByDrift: false)
                == .keepOutput)
    }

    // MARK: - Already-degraded output

    @Test func handsFreeRateReanchors() {
        for rate in [8000, 16000, 24000, 32000] {
            #expect(ClockAnchorPolicy.decide(outputRate: rate, isBluetooth: false, forcedByDrift: false)
                    == .reanchor(.degradedRate),
                    "rate \(rate) should re-anchor")
        }
    }

    // MARK: - THE 2026-08-04 REGRESSION

    /// The bug. A Bluetooth output that currently reports a healthy 48 kHz is NOT safe to clock off:
    /// it can drop to HFP *after* the aggregate is built, and that transition fires no device-change
    /// notification. Its rate at build time predicts nothing, so it must never be trusted as a clock.
    @Test func bluetoothReportingFullRateStillReanchors() {
        #expect(ClockAnchorPolicy.decide(outputRate: 48000, isBluetooth: true, forcedByDrift: false)
                == .reanchor(.bluetoothVolatileRate))
    }

    @Test func bluetoothAlreadyInHandsFreeReanchors() {
        // Degraded-rate is the more specific, more actionable reason — it wins over the generic
        // "bluetooth is volatile".
        #expect(ClockAnchorPolicy.decide(outputRate: 24000, isBluetooth: true, forcedByDrift: false)
                == .reanchor(.degradedRate))
    }

    // MARK: - Drift remediation

    /// The watchdog measured a real shortfall. Whatever the device claims about itself, it is lying:
    /// force the re-anchor.
    @Test func measuredDriftForcesReanchorEvenWhenOutputLooksHealthy() {
        #expect(ClockAnchorPolicy.decide(outputRate: 48000, isBluetooth: false, forcedByDrift: true)
                == .reanchor(.driftRemediation))
    }

    // MARK: - Remediation must be bounded

    /// Rebuilding resets the drift monitor, so a device that keeps drifting would rebuild forever,
    /// tearing a hole in the recording each time. Bound it.
    @Test func remediationIsBounded() {
        #expect(ClockAnchorPolicy.shouldRemediate(attemptsSoFar: 0))
        #expect(ClockAnchorPolicy.shouldRemediate(attemptsSoFar: ClockAnchorPolicy.maxDriftRemediations - 1))
        #expect(!ClockAnchorPolicy.shouldRemediate(attemptsSoFar: ClockAnchorPolicy.maxDriftRemediations))
        #expect(!ClockAnchorPolicy.shouldRemediate(attemptsSoFar: ClockAnchorPolicy.maxDriftRemediations + 5))
    }
}
