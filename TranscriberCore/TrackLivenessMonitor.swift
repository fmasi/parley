import Foundation

/// Pure decision core of the 1 Hz off-audio-queue liveness watchdog, per track (§4.2).
///
/// Judges the HEARTBEAT (the OS calling our audio callback), not the content, from the moment
/// `arm()` says "expect frames from here": capture start, every tap/mic rebuild, every wake.
/// Unlike its predecessor it judges a track that has never delivered — that was Incident B.
/// Both thresholds count only time during which the gate was open (§4.2): the never-delivered clock
/// starts at max(arm, gate open); the stall clock at max(last heartbeat, gate open).
public struct TrackLivenessMonitor: Equatable, Sendable {
    public enum ClearReason: Equatable, Sendable { case heartbeat, gateClosed }

    public enum Verdict: Equatable, Sendable {
        case healthy
        case firstFrames
        case neverDelivered(seconds: Double)
        case stalled(seconds: Double)
        case cleared(ClearReason)
    }

    public let track: String
    public let firstFrameThresholdSeconds: Double
    public let stallThresholdSeconds: Double

    private var armedAtNanos: UInt64?
    /// When the gate was last seen opening. Tracks the GATE, not the generation: an arm() while the
    /// gate is already open must judge from the arm time, not from the next tick.
    private var gateOpenSinceNanos: UInt64?
    private var gateObservedThisGeneration = false
    private var heartbeatSeenThisGeneration = false
    private var firstFramesReported = false
    private var episodeOpen = false
    /// The newest heartbeat known when the open episode began: only a NEWER one ends it. "Last
    /// heartbeat within the stall threshold" is not enough — an accelerator opens the episode 1 s
    /// after the last heartbeat, so the next ticks would read that same heartbeat as a recovery.
    /// `nil` while an externally opened episode waits for its first tick to learn the stamp: the
    /// accelerator saw a heartbeat the monitor's own last tick may predate.
    private var episodeHeartbeatNanos: UInt64?

    public init(track: String, firstFrameThresholdSeconds: Double = 5, stallThresholdSeconds: Double = 3) {
        self.track = track
        self.firstFrameThresholdSeconds = firstFrameThresholdSeconds
        self.stallThresholdSeconds = stallThresholdSeconds
    }

    public var hasOpenEpisode: Bool { episodeOpen }

    public mutating func arm(nowNanos: UInt64) {
        armedAtNanos = nowNanos
        gateObservedThisGeneration = false
        heartbeatSeenThisGeneration = false
        firstFramesReported = false
        episodeOpen = false
        episodeHeartbeatNanos = nil
    }

    public mutating func pause() {
        armedAtNanos = nil
        episodeOpen = false
        episodeHeartbeatNanos = nil
    }

    /// An accelerator reported a stall ahead of the threshold: open the episode so the next tick does
    /// not report the same stall again. Returns false (no-op) when nothing has been delivered this
    /// generation (the never-delivered path owns it) or the monitor is not armed.
    public mutating func openEpisodeExternally() -> Bool {
        guard armedAtNanos != nil, heartbeatSeenThisGeneration, !episodeOpen else { return false }
        episodeOpen = true
        episodeHeartbeatNanos = nil
        return true
    }

    private static func seconds(from: UInt64, to: UInt64) -> Double {
        to > from ? Double(to - from) / 1e9 : 0   // a stamp newer than "now" (two queues) is 0, never negative
    }

    public mutating func check(nowNanos: UInt64, lastHeartbeatNanos: UInt64, gateOpen: Bool) -> Verdict {
        guard let armedAt = armedAtNanos else { return .healthy }
        guard gateOpen else {
            gateOpenSinceNanos = nil
            gateObservedThisGeneration = true
            if episodeOpen {
                episodeOpen = false
                episodeHeartbeatNanos = nil
                return .cleared(.gateClosed)
            }
            return .healthy
        }
        // First observation after an arm with the gate already open: it was open at the arm (the
        // tick is 1 Hz, so this is at most 1 s pessimistic). A closed→open transition starts now.
        if gateOpenSinceNanos == nil { gateOpenSinceNanos = gateObservedThisGeneration ? nowNanos : armedAt }
        gateObservedThisGeneration = true
        let gateOpenSince = gateOpenSinceNanos ?? armedAt

        if lastHeartbeatNanos > armedAt {
            // This generation has delivered.
            heartbeatSeenThisGeneration = true
            if episodeOpen {
                if let openedOn = episodeHeartbeatNanos {
                    if lastHeartbeatNanos > openedOn {
                        episodeOpen = false
                        episodeHeartbeatNanos = nil
                        return .cleared(.heartbeat)
                    }
                } else {
                    episodeHeartbeatNanos = lastHeartbeatNanos   // externally opened: learn the stamp
                }
            }
            if !firstFramesReported { firstFramesReported = true; return .firstFrames }
            let silentWhileExpected = Self.seconds(from: max(lastHeartbeatNanos, gateOpenSince), to: nowNanos)
            if silentWhileExpected >= stallThresholdSeconds, !episodeOpen {
                episodeOpen = true
                episodeHeartbeatNanos = lastHeartbeatNanos
                return .stalled(seconds: silentWhileExpected)
            }
            return .healthy
        }

        let waited = Self.seconds(from: max(armedAt, gateOpenSince), to: nowNanos)
        if waited >= firstFrameThresholdSeconds, !episodeOpen {
            episodeOpen = true
            episodeHeartbeatNanos = armedAt   // any heartbeat of this generation ends it
            return .neverDelivered(seconds: waited)
        }
        return .healthy
    }
}
