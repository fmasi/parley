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
    /// The sleep pause and its exits (A-I7; round 2 items 11, 13, 18): the app's wake, IOKit's full wake,
    /// a promotion seen on a tick, or the bounded expiry — whichever comes first, once. Queue-confined.
    private var sleepPause = SleepPauseClock()
    private let outputActivity = OutputActivityProbe()
    private let gateOpenLock = OSAllocatedUnfairLock<Bool>(initialState: true)

    var lastMicHeartbeatNanos: (() -> UInt64)?
    var lastSystemHeartbeatNanos: (() -> UInt64)?
    /// Every non-healthy verdict, on `queue`: (track, verdict).
    var onVerdict: ((CaptureTrack, TrackLivenessMonitor.Verdict) -> Void)?
    /// The gate state on every tick (for coverage accounting, H6): (gateOpen, nowNanos).
    var onGate: ((Bool, UInt64) -> Void)?
    /// After every tick's verdicts, on `queue`: (nowNanos, gateOpen). The service's counter checks — the
    /// mic reopen deadline and write progress (H2 council) — ride the same 1 Hz tick, no timer of their
    /// own. Not while paused for sleep: nothing is judged then.
    var onTick: ((UInt64, Bool) -> Void)?
    /// The sleep pause ended — by whichever exit came first, exactly once — on `queue`, with the mic work
    /// that waited for it and the reason: both monitors are already re-armed; the service resumes the
    /// healer and the mic.
    var onResumed: ((Set<SleepPauseClock.MicWork>, String) -> Void)?
    /// Read on each tick WHILE paused only: whether the machine is in a full (user) wake — the graphics
    /// capability — so a DarkWake promoted to a full wake without a second power-on still wakes (item 18).
    var fullWakeProbe: (() -> Bool?)?
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

    /// Sleep (the app's or IOKit's; idempotent): nothing is judged until the pause ends (see
    /// `SleepPauseClock`). The tick keeps running (an owed `.cleared(.gateClosed)` is still delivered);
    /// the OS pauses it with the machine. `expiryStartsNow`: no power notifications, so the only exit
    /// besides the app's wake is 30 s of awake uptime from here (round 1's behaviour).
    func pause(expiryStartsNow: Bool, from source: SleepPauseClock.SleepSource) {
        let now = DispatchTime.now().uptimeNanoseconds
        queue.async { [weak self] in
            guard let self else { return }
            self.sleepPause.pause(nowNanos: now, expiryStartsNow: expiryStartsNow, from: source)
            for track in CaptureTrack.allCases { self.monitors[track]?.pause() }
        }
    }

    /// The app's wake. A second wake — the pause already ended by IOKit's full wake or the expiry — is
    /// ignored (item 13).
    func wake() {
        queue.async { [weak self] in
            guard let self, let work = self.sleepPause.wake() else { return }
            self.resume(work, reason: "wake")
        }
    }

    /// IOKit's power-on (item 18): a confirmed full wake is an implicit wake; an unclassified one starts
    /// the expiry clock; a DarkWake leaves the pause alone.
    func poweredOn(fullWake: Bool?) {
        let now = DispatchTime.now().uptimeNanoseconds
        queue.async { [weak self] in
            guard let self else { return }
            if let work = self.sleepPause.poweredOn(fullWake: fullWake, nowNanos: now) {
                self.resume(work, reason: "implicit wake: \(self.sleepPause.lastWakeReason?.rawValue ?? "full wake")")
            } else if self.sleepPause.isPaused {
                Logger.audio.info("Power-on while paused for sleep (\(fullWake == false ? "DarkWake" : "unclassified", privacy: .public)) — pause kept")
            }
        }
    }

    /// Mic work that must not run across a sleep (item 11): kept for the wake while paused, else `run`
    /// now. `run` is called on `queue`.
    func deferMicWork(_ work: SleepPauseClock.MicWork, otherwise run: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.sleepPause.deferMicWork(work) {
                Logger.audio.info("Mic work kept for the wake: \("\(work)", privacy: .public)")
            } else {
                run()
            }
        }
    }

    /// Paused for sleep. Call on `queue` only.
    var isPausedForSleep: Bool { sleepPause.isPaused }

    /// The pause ended: both tracks are judged from now (first frames due in 5 s).
    private func resume(_ work: Set<SleepPauseClock.MicWork>, reason: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        for track in CaptureTrack.allCases { monitors[track]?.arm(nowNanos: now) }
        onResumed?(work, reason)
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
        sleepPause = SleepPauseClock()
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        // While paused: a DarkWake promoted to a full wake, or the expiry after an unclassified power-on
        // (uptime does not advance in sleep), ends the pause (A-I7, item 18). The probe runs only here.
        if sleepPause.isPaused, let work = sleepPause.tick(nowNanos: now, fullWake: fullWakeProbe?()) {
            // "promoted" vs "expired" — the X1 check compares these against `pmset -g log` (round 4 M3).
            let reason = sleepPause.lastWakeReason?.rawValue ?? "unknown"
            Logger.audio.info("Implicit wake — \(reason, privacy: .public) — resuming liveness")
            resume(work, reason: "implicit wake: \(reason)")
        }
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
        if !sleepPause.isPaused { onTick?(now, gateOpen) }
    }
}
