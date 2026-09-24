import Foundation

/// Pure decision core of the 1 Hz off-audio-queue liveness watchdog, per track (§4.2).
///
/// Judges the HEARTBEAT (the OS calling our audio callback), not the content, from the moment
/// `arm()` says "expect frames from here": capture start, every tap/mic rebuild, every wake.
/// Unlike its predecessor it judges a track that has never delivered — that was Incident B.
/// Both thresholds count only time during which the gate was open (§4.2): the never-delivered clock
/// starts at max(arm, gate open); the stall clock at max(last heartbeat, gate open).
///
/// The gate is debounced (fix round 1, owner ruling "never silent"): it counts as closed only after
/// `gateCloseTicks` consecutive closed ticks. A one-tick dropout of a call app's output IO neither
/// clears an open episode nor restarts a clock, so a dead tap behind a flapping gate is still
/// reported, and an alarm does not flicker.
public struct TrackLivenessMonitor: Equatable, Sendable {
    public enum ClearReason: Equatable, Sendable { case heartbeat, gateClosed }

    public enum Verdict: Equatable, Sendable {
        case healthy
        case firstFrames
        case neverDelivered(seconds: Double)
        case stalled(seconds: Double)
        case cleared(ClearReason)
    }

    /// Consecutive closed ticks before the gate counts as closed.
    public static let gateCloseTicks = 2

    public let track: String
    public let firstFrameThresholdSeconds: Double
    public let stallThresholdSeconds: Double

    private var armedAtNanos: UInt64?
    /// When the (debounced) gate opened; `nil` = closed. Tracks the GATE, not the generation, and is
    /// kept up while unarmed too: an arm() while the gate is already open judges from the arm time.
    private var gateOpenSinceNanos: UInt64?
    /// Closed ticks in a row while the gate still counts as open.
    private var closedTicks = 0
    private var gateEverObserved = false
    private var firstFramesReported = false
    /// The newest heartbeat known when the open episode began; `nil` = no open episode. Only a NEWER
    /// heartbeat ends the episode: "last heartbeat within the stall threshold" is not enough, since
    /// an accelerator opens the episode 1 s after the last heartbeat.
    private var episodeOpenedOnNanos: UInt64?
    /// `arm`/`pause` ended an open episode without a verdict. Its alarm is still up, so the next
    /// closed-gate tick reports `.cleared(.gateClosed)` for it; `.firstFrames` or a new episode
    /// (which carry the alarm from here) forget it.
    private var episodeEndedWithoutVerdict = false

    public init(track: String, firstFrameThresholdSeconds: Double = 5, stallThresholdSeconds: Double = 3) {
        self.track = track
        self.firstFrameThresholdSeconds = firstFrameThresholdSeconds
        self.stallThresholdSeconds = stallThresholdSeconds
    }

    public var hasOpenEpisode: Bool { episodeOpenedOnNanos != nil }

    public mutating func arm(nowNanos: UInt64) {
        endEpisodeWithoutVerdict()
        armedAtNanos = nowNanos
        firstFramesReported = false
    }

    public mutating func pause() {
        endEpisodeWithoutVerdict()
        armedAtNanos = nil
    }

    /// An accelerator reported a stall ahead of the threshold: open the episode so the next tick does
    /// not report the same stall again. `stamp` is the last heartbeat the accelerator judged; only a
    /// newer one ends the episode. Returns false (no-op) when the monitor is not armed, an episode is
    /// already open, or this generation's `.firstFrames` has not been reported yet (the monitor's own
    /// never-delivered / first-frames path owns the track until then).
    public mutating func openEpisodeExternally(stamp: UInt64) -> Bool {
        guard armedAtNanos != nil, firstFramesReported, episodeOpenedOnNanos == nil else { return false }
        openEpisode(onHeartbeat: stamp)
        return true
    }

    private static func seconds(from: UInt64, to: UInt64) -> Double {
        to > from ? Double(to - from) / 1e9 : 0   // a stamp newer than "now" (two queues) is 0, never negative
    }

    public mutating func check(nowNanos: UInt64, lastHeartbeatNanos: UInt64, gateOpen: Bool) -> Verdict {
        guard observeGate(gateOpen, nowNanos: nowNanos), let gateOpenSince = gateOpenSinceNanos else {
            if episodeOpenedOnNanos != nil || episodeEndedWithoutVerdict {
                episodeOpenedOnNanos = nil
                episodeEndedWithoutVerdict = false
                return .cleared(.gateClosed)
            }
            return .healthy
        }
        guard let armedAt = armedAtNanos else { return .healthy }

        if lastHeartbeatNanos > armedAt {
            // This generation has delivered.
            if let openedOn = episodeOpenedOnNanos, lastHeartbeatNanos > openedOn {
                episodeOpenedOnNanos = nil
                return .cleared(.heartbeat)
            }
            if !firstFramesReported {
                firstFramesReported = true
                episodeEndedWithoutVerdict = false
                return .firstFrames
            }
            let silentWhileExpected = Self.seconds(from: max(lastHeartbeatNanos, gateOpenSince), to: nowNanos)
            if silentWhileExpected >= stallThresholdSeconds, episodeOpenedOnNanos == nil {
                openEpisode(onHeartbeat: lastHeartbeatNanos)
                return .stalled(seconds: silentWhileExpected)
            }
            return .healthy
        }

        let waited = Self.seconds(from: max(armedAt, gateOpenSince), to: nowNanos)
        if waited >= firstFrameThresholdSeconds, episodeOpenedOnNanos == nil {
            openEpisode(onHeartbeat: armedAt)   // any heartbeat of this generation ends it
            return .neverDelivered(seconds: waited)
        }
        return .healthy
    }

    /// Feed one raw gate reading; returns whether the debounced gate is open.
    private mutating func observeGate(_ open: Bool, nowNanos: UInt64) -> Bool {
        defer { gateEverObserved = true }
        if open {
            closedTicks = 0
            if gateOpenSinceNanos == nil {
                // Never observed before: assume it was open at the arm (the tick is 1 Hz, so this is
                // at most 1 s pessimistic). Seen closed before (in any generation): it opened since
                // that tick, so the clock starts now, never before the gate was seen open.
                gateOpenSinceNanos = gateEverObserved ? nowNanos : (armedAtNanos ?? nowNanos)
            }
            return true
        }
        guard gateOpenSinceNanos != nil else { return false }
        closedTicks += 1
        if closedTicks < Self.gateCloseTicks { return true }   // a dropout: still open
        gateOpenSinceNanos = nil
        closedTicks = 0
        return false
    }

    private mutating func openEpisode(onHeartbeat stamp: UInt64) {
        episodeOpenedOnNanos = stamp
        episodeEndedWithoutVerdict = false
    }

    private mutating func endEpisodeWithoutVerdict() {
        if episodeOpenedOnNanos != nil { episodeEndedWithoutVerdict = true }
        episodeOpenedOnNanos = nil
    }
}
