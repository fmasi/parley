import Foundation

/// Real gap durations per track for the coverage record (§7.1, H review round 1): a silence verdict
/// opens a gap that began `seconds` before it — the monitor measures from the last heartbeat (or the
/// arm) — and the next `.firstFrames` / `.cleared` closes it. The record states the longest gap,
/// one still open included, never the ~3 s it took to detect it.
public struct GapTracker: Equatable, Sendable {
    private var openSince: [CaptureTrack: UInt64] = [:]
    private var counts: [CaptureTrack: Int] = [:]
    private var longestClosed: [CaptureTrack: Double] = [:]

    public init() {}

    public mutating func note(_ verdict: TrackLivenessMonitor.Verdict, track: CaptureTrack, nowNanos: UInt64) {
        switch verdict {
        case .neverDelivered(let seconds), .stalled(let seconds):
            // One gap per silence: an accelerator's early stall and a later verdict are the same gap.
            guard openSince[track] == nil else { return }
            let back = seconds.isFinite && seconds > 0 ? UInt64(seconds * 1e9) : 0
            openSince[track] = nowNanos - min(nowNanos, back)
            counts[track, default: 0] += 1
        case .firstFrames, .cleared:
            guard let start = openSince.removeValue(forKey: track) else { return }
            longestClosed[track] = max(longestClosed[track] ?? 0, Self.seconds(from: start, to: nowNanos))
        case .healthy:
            break
        }
    }

    public func gapCount(_ track: CaptureTrack) -> Int { counts[track] ?? 0 }

    public func longestGapSeconds(_ track: CaptureTrack, nowNanos: UInt64) -> Double {
        let open = openSince[track].map { Self.seconds(from: $0, to: nowNanos) } ?? 0
        return max(longestClosed[track] ?? 0, open)
    }

    private static func seconds(from: UInt64, to: UInt64) -> Double {
        to > from ? Double(to - from) / 1e9 : 0
    }
}
