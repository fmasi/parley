import Testing
@testable import TranscriberCore

/// H2 round 2 item 16 (minor 10): a track's delivery alarm raised because audio arrives but can't be
/// recorded — or raised within 5 s of such an episode — clears only on write progress, never on a
/// heartbeat: a track that comes back with callbacks but still writes nothing must not flicker the
/// alarm off and on.
@Suite struct DeliveryAlarmGateTests {
    @Test func aHeartbeatNeverClearsAnAlarmRaisedWhileWriteStuck() {
        var g = DeliveryAlarmGate()
        g.writeStuck(frames: 100)
        g.alarmRaised(now: 10, frames: 100)
        let clears1 = g.mayClear(.heartbeat)
        #expect(!clears1)
        let progressed2 = g.tick(frames: 100)
        #expect(!progressed2, "no write progress, no clear")
        let clears3 = g.mayClear(.heartbeat)
        #expect(!clears3)
    }

    /// The write monitor's episode ends when frames are written again: the alarm clears with it, and
    /// heartbeats count again afterwards.
    @Test func theWriteEpisodeEndingUnbindsIt() {
        var g = DeliveryAlarmGate()
        g.writeStuck(frames: 100)
        g.alarmRaised(now: 10, frames: 100)
        g.writeRecovered(now: 20)
        let clears = g.mayClear(.heartbeat)
        #expect(clears)
    }

    /// Write progress seen on a tick clears a bound alarm, once.
    @Test func writeProgressOnATickClearsABoundAlarmOnce() {
        var g = DeliveryAlarmGate()
        g.writeStuck(frames: 100)
        g.writeRecovered(now: 20)
        g.alarmRaised(now: 21, frames: 150)
        let first = g.tick(frames: 160)
        let second = g.tick(frames: 170)
        #expect(first)
        #expect(!second)
    }

    /// The flicker: a liveness verdict re-raises the alarm right after the write-stuck episode ended,
    /// then the heartbeat returns with nothing written. Bound: only writes clear it.
    @Test func anAlarmRaisedWithinTheGraceAfterAStuckEpisodeIsWriteBound() {
        var g = DeliveryAlarmGate()
        g.writeStuck(frames: 100)
        g.writeRecovered(now: 20)
        g.alarmRaised(now: 20 + DeliveryAlarmGate.graceSeconds - 1, frames: 150)
        let clears6 = g.mayClear(.heartbeat)
        #expect(!clears6)
        let progressed7 = g.tick(frames: 150)
        #expect(!progressed7)
        let progressed8 = g.tick(frames: 151)
        #expect(progressed8)
    }

    @Test func anAlarmRaisedLongAfterIsAnOrdinaryDeliveryAlarm() {
        var g = DeliveryAlarmGate()
        g.writeStuck(frames: 100)
        g.writeRecovered(now: 20)
        g.alarmRaised(now: 20 + DeliveryAlarmGate.graceSeconds, frames: 150)
        let clears9 = g.mayClear(.heartbeat)
        #expect(clears9)
    }

    @Test func anOrdinaryDeliveryAlarmClearsOnAHeartbeat() {
        var g = DeliveryAlarmGate()
        g.alarmRaised(now: 10, frames: 0)
        let clears10 = g.mayClear(.heartbeat)
        #expect(clears10)
    }

    /// The remote's gate closed: the track is no longer expected, bound or not.
    @Test func theTrackNoLongerExpectedClearsIt() {
        var g = DeliveryAlarmGate()
        g.writeStuck(frames: 100)
        g.alarmRaised(now: 10, frames: 100)
        let clears11 = g.mayClear(.notExpected)
        #expect(clears11)
        let clears12 = g.mayClear(.heartbeat)
        #expect(clears12, "unbound by it")
    }

    @Test func theGraceIsTheWriteStallThreshold() {
        #expect(DeliveryAlarmGate.graceSeconds == WriteProgressMonitor.stuckSeconds)
    }
}
