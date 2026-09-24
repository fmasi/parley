import Testing
@testable import TranscriberCore

/// H1 / L2 / L-N2: a track that NEVER delivers was invisible — `LivenessGapDetector` refused to
/// judge `lastArrivalNanos == 0`, `PadRatioMonitor.finish()` needed a rate it only learned from a
/// frame, and `trackNeverDelivered` could not fire in production. Incident B (2026-09-24, 46 min,
/// 0 callbacks while WebKit ran output) is the end-to-end proof.
@Suite struct TrackLivenessMonitorTests {
    private func ns(_ s: Double) -> UInt64 { UInt64(s * 1_000_000_000) }

    @Test func nothingIsJudgedBeforeArm() {
        var m = TrackLivenessMonitor(track: "system")
        #expect(m.check(nowNanos: ns(100), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)
    }

    /// Incident B: armed, gate open (another process running output), no callback ever.
    @Test func expectedButNeverDeliveredFiresOnceAfterTheFirstFrameThreshold() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(10))
        #expect(m.check(nowNanos: ns(14), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(15), lastHeartbeatNanos: 0, gateOpen: true) == .neverDelivered(seconds: 5))
        #expect(m.check(nowNanos: ns(16), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)   // once
        #expect(m.hasOpenEpisode)
    }

    /// Gotcha #66: recording started before the call — nothing is expected until the gate opens,
    /// and the clock starts when it opens, not when capture started.
    @Test func gateClosedIsNeverAFaultAndTheClockStartsAtGateOpen() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        #expect(m.check(nowNanos: ns(600), lastHeartbeatNanos: 0, gateOpen: false) == .healthy)
        #expect(m.check(nowNanos: ns(601), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(605), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(606), lastHeartbeatNanos: 0, gateOpen: true) == .neverDelivered(seconds: 5))
    }

    @Test func firstHeartbeatAfterArmIsReportedOnce() {
        var m = TrackLivenessMonitor(track: "mic")
        m.arm(nowNanos: ns(0))
        #expect(m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.5), gateOpen: true) == .firstFrames)
        #expect(m.check(nowNanos: ns(2), lastHeartbeatNanos: ns(1.9), gateOpen: true) == .healthy)
    }

    /// A heartbeat from BEFORE the arm is the previous generation's: a rebuild that never resumes
    /// is a never-delivered on the new generation, not a healthy track (the #86 false-success shape).
    @Test func heartbeatFromThePreviousGenerationDoesNotCount() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.5), gateOpen: true)   // delivering
        m.arm(nowNanos: ns(50))                                                       // rebuild
        #expect(m.check(nowNanos: ns(55), lastHeartbeatNanos: ns(49), gateOpen: true) == .neverDelivered(seconds: 5))
    }

    @Test func deliveredThenSilentIsAStallReportedOnce() {
        var m = TrackLivenessMonitor(track: "mic", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.9), gateOpen: true)
        var fired = 0
        for t in stride(from: 2.0, through: 30.0, by: 1.0) {
            if case .stalled = m.check(nowNanos: ns(t), lastHeartbeatNanos: ns(1), gateOpen: true) { fired += 1 }
        }
        #expect(fired == 1)
    }

    @Test func aHeartbeatClearsTheEpisodeAndReArmsIt() {
        var m = TrackLivenessMonitor(track: "mic", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.9), gateOpen: true)
        #expect(m.check(nowNanos: ns(5), lastHeartbeatNanos: ns(1), gateOpen: true) == .stalled(seconds: 4))
        #expect(m.check(nowNanos: ns(6), lastHeartbeatNanos: ns(5.9), gateOpen: true) == .cleared(.heartbeat))
        #expect(!m.hasOpenEpisode)
        #expect(m.check(nowNanos: ns(10), lastHeartbeatNanos: ns(6), gateOpen: true) == .stalled(seconds: 4))
    }

    /// The gate counts as closed after `gateCloseTicks` (2) consecutive closed ticks (fix round 1).
    @Test func gateClosingClearsAnOpenEpisode() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(5), lastHeartbeatNanos: 0, gateOpen: true)   // neverDelivered
        #expect(m.check(nowNanos: ns(6), lastHeartbeatNanos: 0, gateOpen: false) == .healthy, "one closed tick is a dropout")
        #expect(m.check(nowNanos: ns(7), lastHeartbeatNanos: 0, gateOpen: false) == .cleared(.gateClosed))
    }

    /// Review focus 1: a call app toggling its output IO every second must not produce a report
    /// per flap. Fix round 1 (owner ruling, "never silent"): a single closed tick is a dropout, not a
    /// close, so a 1 Hz flap is an open gate — the dead tap is reported, exactly once, and never
    /// cleared by the flap.
    @Test func gateFlapReportsAtMostOncePerEpisode() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        var reports = 0, cleared = 0
        for t in 1...40 {
            let open = t % 2 == 0
            switch m.check(nowNanos: ns(Double(t)), lastHeartbeatNanos: 0, gateOpen: open) {
            case .neverDelivered: reports += 1
            case .cleared: cleared += 1
            default: break
            }
        }
        #expect(reports == 1 && cleared == 0)
    }

    /// Fix round 1: before the debounce, a gate that dropped out for one tick every 3 s restarted the
    /// never-delivered clock each time, so a dead tap was never reported.
    @Test func aDeadTapIsReportedThroughOneTickGateDropouts() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        var reports = 0, cleared = 0
        for t in 1...40 {
            switch m.check(nowNanos: ns(Double(t)), lastHeartbeatNanos: 0, gateOpen: t % 3 != 0) {
            case .neverDelivered: reports += 1
            case .cleared: cleared += 1
            default: break
            }
        }
        #expect(reports == 1 && cleared == 0)
    }

    /// A one-tick dropout neither clears an open stall nor restarts the stall clock; two closed ticks do.
    @Test func aOneTickDropoutDoesNotClearAStallOrRestartItsClock() {
        var m = TrackLivenessMonitor(track: "mic", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(1), gateOpen: true)                 // firstFrames
        #expect(m.check(nowNanos: ns(2), lastHeartbeatNanos: ns(1), gateOpen: false) == .healthy)
        #expect(m.check(nowNanos: ns(3), lastHeartbeatNanos: ns(1), gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(4), lastHeartbeatNanos: ns(1), gateOpen: true) == .stalled(seconds: 3), "measured from the heartbeat, through the dropout")
        #expect(m.check(nowNanos: ns(5), lastHeartbeatNanos: ns(1), gateOpen: false) == .healthy)
        #expect(m.check(nowNanos: ns(6), lastHeartbeatNanos: ns(1), gateOpen: false) == .cleared(.gateClosed))
    }

    /// Spec §4.2 (scan C5): "no heartbeat for stallThreshold WHILE THE GATE IS OPEN". Under
    /// tap_auto_start=true a call app resuming output after a minute of idle must not be judged
    /// stalled by 60 s on the first open tick: the stall clock starts at the gate opening.
    @Test func stallIsMeasuredFromGateOpenNotFromTheLastHeartbeat() {
        var m = TrackLivenessMonitor(track: "system", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        #expect(m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.9), gateOpen: true) == .firstFrames)
        for t in 2...60 {
            #expect(m.check(nowNanos: ns(Double(t)), lastHeartbeatNanos: ns(1), gateOpen: false) == .healthy)
        }
        #expect(m.check(nowNanos: ns(61), lastHeartbeatNanos: ns(1), gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(63), lastHeartbeatNanos: ns(1), gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(64), lastHeartbeatNanos: ns(1), gateOpen: true) == .stalled(seconds: 3))
    }

    /// Spec §4.2 (scan C5): each gate-open period ≥ threshold over a still-dead track is one episode.
    @Test func aSlowGateFlapOverADeadTrackReportsOncePerOpenPeriod() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        var reports = 0, cleared = 0
        for t in 1...40 {
            let open = (t / 10) % 2 == 0   // 10 s open, 10 s closed, …
            switch m.check(nowNanos: ns(Double(t)), lastHeartbeatNanos: 0, gateOpen: open) {
            case .neverDelivered: reports += 1
            case .cleared(.gateClosed): cleared += 1
            default: break
            }
        }
        #expect(reports == 2 && cleared == 2)
    }

    /// Review focus 3: heartbeats are stamped on the audio queue and read on the watchdog queue.
    @Test func heartbeatInTheFutureIsHealthy() {
        var m = TrackLivenessMonitor(track: "mic")
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.5), gateOpen: true)
        #expect(m.check(nowNanos: ns(2), lastHeartbeatNanos: ns(2.5), gateOpen: true) == .healthy)
    }

    @Test func pauseSuspendsJudgementUntilTheNextArm() {
        var m = TrackLivenessMonitor(track: "mic", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.9), gateOpen: true)
        m.pause()
        #expect(m.check(nowNanos: ns(100), lastHeartbeatNanos: ns(1), gateOpen: true) == .healthy)
        m.arm(nowNanos: ns(100))
        #expect(m.check(nowNanos: ns(105), lastHeartbeatNanos: ns(1), gateOpen: true) == .neverDelivered(seconds: 5))
    }

    /// Scan A26: an aggregate listener lets the driver report a stall 1 s after the event, before the
    /// 3 s threshold. That early report opens the episode, so the monitor's own tick two seconds
    /// later does not report the same stall a second time; the heartbeat still clears it.
    @Test func anExternallyOpenedEpisodeIsNotReportedAgainAndClearsOnHeartbeat() {
        var m = TrackLivenessMonitor(track: "system", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.9), gateOpen: true)
        let opened = m.openEpisodeExternally(stamp: ns(1))   // a bare mutating call does not compile inside #expect
        #expect(opened)
        #expect(m.hasOpenEpisode)
        #expect(m.check(nowNanos: ns(5), lastHeartbeatNanos: ns(1), gateOpen: true) == .healthy, "already reported by the accelerator")
        #expect(m.check(nowNanos: ns(6), lastHeartbeatNanos: ns(5.9), gateOpen: true) == .cleared(.heartbeat))
    }

    /// Scan A26, the ticks right after the early report: the last heartbeat is still inside the stall
    /// threshold (the accelerator fired 1 s after it), and it is newer than anything the monitor's own
    /// ticks saw. That is the silence the accelerator reported, not a heartbeat: no spurious
    /// `.cleared(.heartbeat)`, and so no second `.stalled` for the same silence when the threshold passes.
    @Test func anEarlyExternalEpisodeIsNotClearedByTheHeartbeatItWasOpenedOn() {
        var m = TrackLivenessMonitor(track: "system", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        #expect(m.check(nowNanos: ns(10), lastHeartbeatNanos: ns(9.9), gateOpen: true) == .firstFrames)
        // The IOProc stops at 10.2 ('stpd'); the accelerator checks at 11.2 and reports the stall.
        let opened = m.openEpisodeExternally(stamp: ns(10.2))
        #expect(opened)
        #expect(m.check(nowNanos: ns(12), lastHeartbeatNanos: ns(10.2), gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(13), lastHeartbeatNanos: ns(10.2), gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(14), lastHeartbeatNanos: ns(10.2), gateOpen: true) == .healthy, "same stall, already reported")
        #expect(m.hasOpenEpisode)
        #expect(m.check(nowNanos: ns(15), lastHeartbeatNanos: ns(14.5), gateOpen: true) == .cleared(.heartbeat))
    }

    /// Fix round 1: the accelerator hands in the heartbeat it judged, so a heartbeat resuming between
    /// the accelerator and the next tick clears at that tick, not one later.
    @Test func aHeartbeatResumingRightAfterTheAcceleratorClearsAtTheNextTick() {
        var m = TrackLivenessMonitor(track: "system", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(10), lastHeartbeatNanos: ns(9.9), gateOpen: true)             // firstFrames
        let opened = m.openEpisodeExternally(stamp: ns(10.2))                                    // at 11.2
        #expect(opened)
        #expect(m.check(nowNanos: ns(12), lastHeartbeatNanos: ns(11.9), gateOpen: true) == .cleared(.heartbeat))
    }

    @Test func anExternalStallBeforeAnyHeartbeatIsRefused() {
        var m = TrackLivenessMonitor(track: "system")
        m.arm(nowNanos: ns(0))
        #expect(m.openEpisodeExternally(stamp: 0) == false, "never-delivered owns a track that has not delivered")
        var unarmed = TrackLivenessMonitor(track: "system")
        #expect(unarmed.openEpisodeExternally(stamp: 0) == false)
    }

    /// Fix round 1 (introduced by the round-0 deviation): after a never-delivered episode, the first
    /// burst clears it but `.firstFrames` comes a tick later. An accelerator in between used to open an
    /// episode that the `.firstFrames` tick then left open, silencing the monitor for the rest of the
    /// generation while the tap was dead. It is refused until `.firstFrames` has been reported.
    @Test func anAcceleratorCannotOpenAnEpisodeBeforeFirstFramesAreReported() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5, stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        #expect(m.check(nowNanos: ns(5), lastHeartbeatNanos: 0, gateOpen: true) == .neverDelivered(seconds: 5))
        #expect(m.check(nowNanos: ns(6), lastHeartbeatNanos: ns(5.6), gateOpen: true) == .cleared(.heartbeat))   // a burst ending at 5.6
        #expect(m.openEpisodeExternally(stamp: ns(5.6)) == false)                                              // at 6.6
        #expect(m.check(nowNanos: ns(7), lastHeartbeatNanos: ns(5.6), gateOpen: true) == .firstFrames)
        var stalls = 0
        for t in 8...40 {
            if case .stalled = m.check(nowNanos: ns(Double(t)), lastHeartbeatNanos: ns(5.6), gateOpen: true) { stalls += 1 }
        }
        #expect(stalls == 1, "the dead tap is reported, once")
    }

    /// Fix round 1: `arm` (a rebuild) ends an open episode without a verdict. If the call then ends, the
    /// NotDelivering alarm must still be cleared: the gate closing emits `.cleared(.gateClosed)`.
    @Test func anEpisodeEndedByARearmIsClearedWhenTheGateCloses() {
        var m = TrackLivenessMonitor(track: "system", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.9), gateOpen: true)              // firstFrames
        #expect(m.check(nowNanos: ns(5), lastHeartbeatNanos: ns(1), gateOpen: true) == .stalled(seconds: 4))
        m.arm(nowNanos: ns(6))                                                                  // ladder rebuild
        #expect(m.check(nowNanos: ns(7), lastHeartbeatNanos: ns(1), gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(8), lastHeartbeatNanos: ns(1), gateOpen: false) == .healthy)
        #expect(m.check(nowNanos: ns(9), lastHeartbeatNanos: ns(1), gateOpen: false) == .cleared(.gateClosed))
        #expect(m.check(nowNanos: ns(10), lastHeartbeatNanos: ns(1), gateOpen: false) == .healthy, "once")
    }

    /// The same after `pause` (sleep): the clear does not wait for the next arm.
    @Test func anEpisodeEndedByAPauseIsClearedWhenTheGateCloses() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(5), lastHeartbeatNanos: 0, gateOpen: true)                    // neverDelivered
        m.pause()
        #expect(m.check(nowNanos: ns(6), lastHeartbeatNanos: 0, gateOpen: false) == .healthy)
        #expect(m.check(nowNanos: ns(7), lastHeartbeatNanos: 0, gateOpen: false) == .cleared(.gateClosed))
    }

    /// The remembered clear is forgotten once the new generation delivers: `.firstFrames` already
    /// cleared the alarm, so a later gate close has nothing to clear.
    @Test func anEpisodeEndedByARearmIsForgottenOnFirstFrames() {
        var m = TrackLivenessMonitor(track: "system", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(1), lastHeartbeatNanos: ns(0.9), gateOpen: true)
        _ = m.check(nowNanos: ns(5), lastHeartbeatNanos: ns(1), gateOpen: true)                // stalled
        m.arm(nowNanos: ns(6))
        #expect(m.check(nowNanos: ns(7), lastHeartbeatNanos: ns(6.5), gateOpen: true) == .firstFrames)
        _ = m.check(nowNanos: ns(8), lastHeartbeatNanos: ns(7.9), gateOpen: false)
        #expect(m.check(nowNanos: ns(9), lastHeartbeatNanos: ns(7.9), gateOpen: false) == .healthy)
    }

    /// Fix round 1: when the tick before the arm saw the gate closed, the gate opened after it, so the
    /// never-delivered clock starts at the first open tick, not at the arm (up to 1 s early otherwise).
    @Test func aGateSeenClosedBeforeTheArmStartsTheClockWhenItOpens() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(9), lastHeartbeatNanos: 0, gateOpen: false)
        m.arm(nowNanos: ns(9.5))
        #expect(m.check(nowNanos: ns(10.5), lastHeartbeatNanos: 0, gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(14.5), lastHeartbeatNanos: 0, gateOpen: true) == .healthy, "4 s since the gate opened")
        #expect(m.check(nowNanos: ns(15.5), lastHeartbeatNanos: 0, gateOpen: true) == .neverDelivered(seconds: 5))
    }
}
