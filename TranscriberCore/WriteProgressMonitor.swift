import Foundation

/// Per-track WRITE progress (H2 council, A-I3), next to `TrackLivenessMonitor`'s heartbeat. The OS
/// calling us is not us writing: a converter that fails on every buffer, an unsupported mic format,
/// a sticky format drop — the heartbeat flows, nothing reaches the WAV, and the liveness monitor
/// (rightly) sees a healthy callback. For the mic this was a regression: before the overhaul its
/// liveness was stamped after conversion.
///
/// Judged on the existing 1 Hz tick, from counters: while the track is expected and its heartbeat
/// flows, written (real, never padded) frames must grow within `stuckSeconds`. Time without a
/// heartbeat does not count — that silence is the liveness monitor's. The gate is debounced like the
/// liveness monitor's, so a one-tick dropout of a call app's output neither clears nor restarts.
public struct WriteProgressMonitor: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case none
        /// Called but not writing for `seconds`: once per episode.
        case stuck(seconds: Double)
        /// A reported episode ended: frames were written again, or the track is no longer expected.
        case cleared
    }

    public static let stuckSeconds: Double = 5
    /// A heartbeat younger than this "flows": the liveness monitor's stall threshold.
    public static let heartbeatFlowingSeconds: Double = 3

    private var lastFrames: Int64?
    /// Since when the track has been called, expected and not writing; `nil` = not judging.
    private var judgingSinceNanos: UInt64?
    private var reported = false
    /// The debounced gate (always open for the mic, which passes `expected: true`).
    private var gateOpen = false
    private var closedTicks = 0

    public init() {}

    public mutating func check(nowNanos: UInt64, lastHeartbeatNanos: UInt64, expected: Bool, writtenFrames: Int64) -> Verdict {
        let progressed = lastFrames.map { writtenFrames != $0 } ?? false
        lastFrames = writtenFrames
        let expectedNow = observeGate(expected)
        let flowing = lastHeartbeatNanos != 0
            && Self.seconds(from: lastHeartbeatNanos, to: nowNanos) < Self.heartbeatFlowingSeconds
        if progressed || !expectedNow {
            judgingSinceNanos = expectedNow && flowing ? nowNanos : nil
            guard reported else { return .none }
            reported = false
            return .cleared
        }
        guard flowing else {
            judgingSinceNanos = nil
            return .none
        }
        guard let since = judgingSinceNanos else {
            judgingSinceNanos = nowNanos
            return .none
        }
        let silent = Self.seconds(from: since, to: nowNanos)
        guard silent >= Self.stuckSeconds, !reported else { return .none }
        reported = true
        return .stuck(seconds: silent)
    }

    /// Feed one raw gate reading; returns whether the debounced gate is open.
    private mutating func observeGate(_ open: Bool) -> Bool {
        if open {
            gateOpen = true
            closedTicks = 0
        } else if gateOpen {
            closedTicks += 1
            if closedTicks >= TrackLivenessMonitor.gateCloseTicks {
                gateOpen = false
                closedTicks = 0
            }
        }
        return gateOpen
    }

    private static func seconds(from: UInt64, to: UInt64) -> Double {
        to > from ? Double(to - from) / 1e9 : 0
    }
}

/// Which clears a track's delivery alarm (`micNotDelivering` / `remoteNotDelivering`) may take (H2
/// round 2 item 16). An alarm raised while the track is called but writes nothing — or raised within
/// `graceSeconds` of such an episode ending — is WRITE-BOUND: it clears only on write progress (or when
/// the track is no longer expected), never on a heartbeat. Otherwise a track that returns with
/// callbacks but still writes nothing flickers the alarm off and on. One per track.
public struct DeliveryAlarmGate: Equatable, Sendable {
    public enum ClearReason: Equatable, Sendable {
        /// First frames, a heartbeat after a stall, a reopen that delivered, the healer's recovery.
        case heartbeat
        /// The track is no longer expected (the remote's gate closed).
        case notExpected
    }

    public static let graceSeconds = WriteProgressMonitor.stuckSeconds

    private var stuck = false
    private var stuckEndedAt: Double?
    private var writeBound = false
    /// Written frames when the alarm became write-bound: only more than this is write progress.
    private var framesAtBind: Int64 = 0

    public init() {}

    /// The write monitor reported the track called but not writing; its alarm is write-bound.
    public mutating func writeStuck(frames: Int64) {
        stuck = true
        bind(frames: frames)
    }

    /// The write monitor's episode ended (frames written again, or the track no longer expected): the
    /// alarm clears now, and one raised within `graceSeconds` from here is write-bound again.
    public mutating func writeRecovered(now: Double) {
        stuck = false
        stuckEndedAt = now
        writeBound = false
    }

    /// The track's delivery alarm was raised (by anyone: the write check, a liveness verdict, the
    /// healer's give-up, the reopen deadline), with the written frames at that moment.
    public mutating func alarmRaised(now: Double, frames: Int64) {
        guard !writeBound else { return }
        if stuck || stuckEndedAt.map({ now - $0 < Self.graceSeconds }) == true { bind(frames: frames) }
    }

    /// May the alarm clear for `reason`? A heartbeat may not clear a write-bound alarm; the track no
    /// longer being expected always may, and unbinds it.
    public mutating func mayClear(_ reason: ClearReason) -> Bool {
        switch reason {
        case .heartbeat:
            return !writeBound
        case .notExpected:
            writeBound = false
            return true
        }
    }

    /// Every tick, with the written frames: true once when a write-bound alarm sees write progress —
    /// the one evidence that clears it.
    public mutating func tick(frames: Int64) -> Bool {
        guard writeBound, !stuck, frames > framesAtBind else { return false }
        writeBound = false
        return true
    }

    private mutating func bind(frames: Int64) {
        if !writeBound { framesAtBind = frames }
        writeBound = true
    }
}
