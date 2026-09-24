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
