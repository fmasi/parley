import Foundation
import os
import TranscriberCore

/// Off-audio-queue 1 Hz driver for the per-track `TrackLivenessMonitor`s (§4.2). Owns the timer
/// on its OWN serial queue — a callback that stopped cannot notice its own silence.
///
/// Strictly 1 Hz: `TrackLivenessMonitor.gateCloseTicks` debounces the gate by counting ticks, so
/// nothing else may call `tick()`. `check` runs every tick whether or not a monitor is armed (it
/// tracks the gate while unarmed and owes a `.cleared(.gateClosed)` after `pause`).
///
/// The system track's heartbeat source is whatever captures system audio (the tap's callback, or
/// the SCK arrival stamp): SCK inherits the liveness watchdog and its alarms for free (§13).
final class LivenessWatchdogDriver {
    let queue = DispatchQueue(label: "audio-capture.liveness-watchdog")
    private var timer: DispatchSourceTimer?
    private var monitors = LivenessWatchdogDriver.freshMonitors()
    private let outputActivity = OutputActivityProbe()
    private let gateOpenLock = OSAllocatedUnfairLock<Bool>(initialState: true)

    var lastMicHeartbeatNanos: (() -> UInt64)?
    var lastSystemHeartbeatNanos: (() -> UInt64)?
    /// Every non-healthy verdict, on `queue`: (track, verdict).
    var onVerdict: ((CaptureTrack, TrackLivenessMonitor.Verdict) -> Void)?
    /// The gate state on every tick (for coverage accounting, H6): (gateOpen, nowNanos).
    var onGate: ((Bool, UInt64) -> Void)?
    /// After every tick's verdicts, on `queue`: (nowNanos, gateOpen). The service's counter checks — the
    /// mic reopen deadline and write progress (H2 council) — ride the same 1 Hz tick, no timer of their own.
    var onTick: ((UInt64, Bool) -> Void)?
    /// The last tick's gate reading. Cheap and lock-only, so `trackHealth()` (H6) can read it from
    /// the audio queue; the probe itself is a HAL read and must not run there.
    var lastGateOpen: Bool { gateOpenLock.withLock { $0 } }

    private static func freshMonitors() -> [CaptureTrack: TrackLivenessMonitor] {
        [.mic: TrackLivenessMonitor(track: CaptureTrack.mic.rawValue),
         .system: TrackLivenessMonitor(track: CaptureTrack.system.rawValue)]
    }

    /// `shouldRun` is asked on `queue`, after any `stop()` queued before this start: a stop that
    /// landed first leaves no timer running past its session (mirrors the tap-guard timer's guard).
    func start(shouldRun: @escaping () -> Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()   // also fresh, unarmed monitors
            guard shouldRun() else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
        }
    }

    /// Also disarms both monitors, so an `accelerate` already scheduled is inert after the stop.
    func stop() { queue.async { [weak self] in self?.stopLocked() } }

    /// Start / rebuild / wake of one track: judge from now, expect first frames within 5 s.
    func arm(track: CaptureTrack) {
        let now = DispatchTime.now().uptimeNanoseconds
        queue.async { [weak self] in self?.monitors[track]?.arm(nowNanos: now) }
    }

    /// Sleep: nothing is judged until the next arm. The tick keeps running (an owed
    /// `.cleared(.gateClosed)` is still delivered), the OS pauses it with the machine.
    func pause() {
        queue.async { [weak self] in
            guard let self else { return }
            for track in CaptureTrack.allCases { self.monitors[track]?.pause() }
        }
    }

    /// An aggregate listener (`goin`→0, `stpd`, `diff`) said IO may have stopped. Accelerators never
    /// rebuild blindly (§5): one second later, if no heartbeat has arrived since the event and the
    /// track is expected, report a stall now instead of waiting for the 3 s threshold. The monitor's
    /// episode is opened on the heartbeat that was judged, so its own tick does not report the same
    /// stall again and only a NEWER heartbeat clears it (C3 round 1). The gate is checked first: a
    /// `goin`→0 that IS the last output process leaving must not raise a false stall (C3 concern).
    func accelerate(track: CaptureTrack) {
        let eventNanos = DispatchTime.now().uptimeNanoseconds
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let heartbeat = self.heartbeat(of: track)
            let expected = track == .mic || self.outputActivity.othersRunningOutput()
            guard heartbeat <= eventNanos, expected else { return }
            guard var m = self.monitors[track], m.openEpisodeExternally(stamp: heartbeat) else { return }
            self.monitors[track] = m
            // The silence so far, from the heartbeat judged: the gap record starts there.
            let now = DispatchTime.now().uptimeNanoseconds
            self.onVerdict?(track, .stalled(seconds: now > heartbeat ? Double(now - heartbeat) / 1e9 : 1))
        }
    }

    private func heartbeat(of track: CaptureTrack) -> UInt64 {
        (track == .mic ? lastMicHeartbeatNanos : lastSystemHeartbeatNanos)?() ?? 0
    }

    private func stopLocked() {
        timer?.cancel(); timer = nil
        monitors = Self.freshMonitors()
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let gateOpen = outputActivity.othersRunningOutput()
        gateOpenLock.withLock { $0 = gateOpen }
        onGate?(gateOpen, now)
        for track in CaptureTrack.allCases {
            guard var m = monitors[track] else { continue }
            // The mic is always expected; only the tap has a gate (§4.3).
            let v = m.check(nowNanos: now, lastHeartbeatNanos: heartbeat(of: track), gateOpen: track == .mic ? true : gateOpen)
            monitors[track] = m
            if v != .healthy { onVerdict?(track, v) }
        }
        onTick?(now, gateOpen)
    }
}
