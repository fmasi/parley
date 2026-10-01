import Foundation
import TranscriberCore

/// Off-audio-queue 1 Hz driver for the #196 capture-liveness watchdog.
///
/// Owns a `DispatchSourceTimer` on its OWN serial queue — never the audio/delivery queue that the
/// real-time IOProc/SCStream callbacks run on. That is the entire point: a track that stops
/// delivering can never notice its own silence from inside the callback that isn't firing, so
/// detecting a gap has to live outside the path that might be the thing that's stuck.
///
/// All the actual judgement is `LivenessGapDetector` (pure, unit-tested); this class only owns the
/// timer and wires it to the handler's arrival timestamps + the tap's `isRunningSomewhere` gate.
final class LivenessWatchdogDriver {
    private let queue = DispatchQueue(label: "audio-capture.liveness-watchdog")
    private var timer: DispatchSourceTimer?

    private var micDetector = LivenessGapDetector(track: "mic")
    private var systemDetector = LivenessGapDetector(track: "system")

    /// Last mic / system buffer arrival, read each tick. Both closures must be cheap and safe to
    /// call from a background queue — `AudioOutputHandler`'s getters already are (lock-guarded,
    /// same pattern as the #86 restart probe).
    var lastMicArrivalNanos: (() -> UInt64)?
    var lastSystemArrivalNanos: (() -> UInt64)?
    /// Whether the system-audio track is the Core Audio tap. The tap legitimately delivers nothing
    /// while system output is idle (gotcha #66), so its gap check must additionally gate on
    /// `SystemTapSession.isOutputDeviceRunningSomewhere()`. SCK keeps delivering zero-filled buffers
    /// even in silence, so it needs no such gate.
    var isUsingSystemTap = false
    /// Invoked (on `queue`) when either track opens a liveness gap.
    var onGap: ((CaptureEventKind, String) -> Void)?
    /// Also invoked (on `queue`) when the SYSTEM track opens a gap, so the tap's permission guard can
    /// check whether a denial is the cause (#220).
    var onSystemGap: (() -> Void)?

    /// `start`/`stop` are called from at least four `AudioCaptureService` teardown
    /// paths with no shared lock, so a concurrent `stop()`+`stop()` or `start()`+`stop()` would be
    /// an unsynchronised read/write on `timer`. Serializing both onto `queue` (already the timer's
    /// own serial queue, and never touched by `tick()` itself) fixes the race without adding a
    /// separate lock. Dispatched `async`, not `sync`: `start()` is called from inside a Swift
    /// `Task`, and a synchronous `queue.sync` there would block a cooperative-thread-pool thread —
    /// nothing requires the caller to wait for the timer to actually be armed before proceeding,
    /// and `async` onto the same serial queue still fully serializes the mutations relative to
    /// every other `start`/`stop` call.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
        }
    }

    /// Idempotent.
    func stop() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    /// Must only be called while already running on `queue`.
    private func stopLocked() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds

        if let lastMicArrivalNanos {
            if case .gap(let seconds) = micDetector.check(
                nowNanos: now, lastArrivalNanos: lastMicArrivalNanos(), gateOpen: true
            ) {
                onGap?(.livenessGap, "The microphone stopped delivering audio \(Int(seconds))s ago.")
            }
        }
        if let lastSystemArrivalNanos {
            let gateOpen = isUsingSystemTap ? SystemTapSession.isOutputDeviceRunningSomewhere() : true
            if case .gap(let seconds) = systemDetector.check(
                nowNanos: now, lastArrivalNanos: lastSystemArrivalNanos(), gateOpen: gateOpen
            ) {
                onGap?(.livenessGap, "System audio stopped delivering \(Int(seconds))s ago.")
                onSystemGap?()
            }
        }
    }
}
