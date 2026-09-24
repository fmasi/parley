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

    @Test func gateClosingClearsAnOpenEpisode() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        _ = m.check(nowNanos: ns(5), lastHeartbeatNanos: 0, gateOpen: true)   // neverDelivered
        #expect(m.check(nowNanos: ns(6), lastHeartbeatNanos: 0, gateOpen: false) == .cleared(.gateClosed))
    }

    /// Review focus 1: a call app toggling its output IO every second must not produce a report
    /// per flap. Only a gap that has been continuously open for the threshold is reported.
    @Test func gateFlapReportsAtMostOncePerEpisode() {
        var m = TrackLivenessMonitor(track: "system", firstFrameThresholdSeconds: 5)
        m.arm(nowNanos: ns(0))
        var reports = 0
        for t in 1...40 {
            let open = t % 2 == 0
            if case .neverDelivered = m.check(nowNanos: ns(Double(t)), lastHeartbeatNanos: 0, gateOpen: open) { reports += 1 }
        }
        #expect(reports == 0, "the gate never stayed open for 5 s, so nothing was expected for 5 s")
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
        let opened = m.openEpisodeExternally()   // a bare mutating call does not compile inside #expect
        #expect(opened)
        #expect(m.hasOpenEpisode)
        #expect(m.check(nowNanos: ns(5), lastHeartbeatNanos: ns(1), gateOpen: true) == .healthy, "already reported by the accelerator")
        #expect(m.check(nowNanos: ns(6), lastHeartbeatNanos: ns(5.9), gateOpen: true) == .cleared(.heartbeat))
    }

    /// Scan A26, the ticks right after the early report: the last heartbeat is still inside the stall
    /// threshold (the accelerator fired 1 s after it), and it may be newer than anything the monitor's
    /// own ticks saw. That is the silence the accelerator reported, not a heartbeat: no spurious
    /// `.cleared(.heartbeat)`, and so no second `.stalled` for the same silence when the threshold passes.
    @Test func anEarlyExternalEpisodeIsNotClearedByTheHeartbeatItWasOpenedOn() {
        var m = TrackLivenessMonitor(track: "system", stallThresholdSeconds: 3)
        m.arm(nowNanos: ns(0))
        #expect(m.check(nowNanos: ns(10), lastHeartbeatNanos: ns(9.9), gateOpen: true) == .firstFrames)
        // The IOProc stops at 10.2 ('stpd'); the accelerator checks at 11.2 and reports the stall.
        let opened = m.openEpisodeExternally()
        #expect(opened)
        #expect(m.check(nowNanos: ns(12), lastHeartbeatNanos: ns(10.2), gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(13), lastHeartbeatNanos: ns(10.2), gateOpen: true) == .healthy)
        #expect(m.check(nowNanos: ns(14), lastHeartbeatNanos: ns(10.2), gateOpen: true) == .healthy, "same stall, already reported")
        #expect(m.hasOpenEpisode)
        #expect(m.check(nowNanos: ns(15), lastHeartbeatNanos: ns(14.5), gateOpen: true) == .cleared(.heartbeat))
    }

    @Test func anExternalStallBeforeAnyHeartbeatIsRefused() {
        var m = TrackLivenessMonitor(track: "system")
        m.arm(nowNanos: ns(0))
        #expect(m.openEpisodeExternally() == false, "never-delivered owns a track that has not delivered")
        var unarmed = TrackLivenessMonitor(track: "system")
        #expect(unarmed.openEpisodeExternally() == false)
    }
}
