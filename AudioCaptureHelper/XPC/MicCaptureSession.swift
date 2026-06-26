import AVFoundation
import CoreAudio
import Foundation
import os
import TranscriberCore

/// Captures the microphone via `AVCaptureSession` + `AVCaptureAudioDataOutput`, decoupled from the
/// system-audio `SCStream` (#96).
///
/// Why this exists: previously ONE `SCStream` captured both system audio and the mic, so any mic
/// route change (AirPods connect/disconnect, HFP↔A2DP) stopped the whole stream — the root cause of
/// the "recording crashed mid-call, lost minutes" incidents. With the mic on its own
/// `AVCaptureSession`, a mic route change can no longer tear down system-audio capture. The session
/// follows audio-device changes via a **Core Audio HAL listener** (gotcha #55 — AVFoundation's audio
/// disconnect notifications don't fire on macOS): on "System Default" it **auto-follows** the system
/// default input (AirPods in/out — the user never has to pick a mic); an explicit pin falls back to the
/// default when its device vanishes and re-pins when it returns. System audio records on, uninterrupted.
///
/// macOS hands `AVCaptureSession` the OS-fused mono for the built-in mic (not the raw 3-channel
/// beamforming array `SCStream` exposed), so the multichannel-array problem disappears at the source
/// for the built-in mic. A genuinely multichannel USB interface is still normalized downstream by
/// `AudioOutputHandler` (which averages >2 channels — see `MultichannelDownmix`).
///
/// Sample buffers are delivered on the caller-supplied `deliveryQueue` — the capture service's single
/// persistent audio queue — so mic appends serialize with system-audio appends, chunk-rotation writer
/// swaps, and finalization on ONE serial queue, preserving the single-writer-queue invariant.
final class MicCaptureSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let deliveryQueue: DispatchQueue
    private let onSampleBuffer: (CMSampleBuffer) -> Void

    /// Invoked after the session self-heals a device disconnect / runtime error by rebuilding around
    /// the pinned (or fallback) device. Passes the resolved device UID (`nil` = system default) so the
    /// app can update the menu label without surfacing a banner. No audio is lost beyond the brief
    /// switch gap; the same mic WAV continues.
    var onRecovered: ((String?) -> Void)?
    /// Invoked when the mic cannot be (re)started within budget. Mic loss is NOT fatal to the session
    /// — system audio keeps recording — so the service records an anomaly and continues; the partial
    /// mic WAV captured up to the loss remains valid.
    var onUnavailable: ((String) -> Void)?
    /// Records a diagnostic event (route change, recovery, error) into the helper's anomaly ring.
    var onEvent: ((CaptureEventKind, CaptureEvent.Severity, [String: String]) -> Void)?

    /// Guards `session`, the device ids, and the recovery flags. A leaf lock — its critical sections
    /// never call out (no `configQueue`, no `startRunning`), so it can't deadlock with `configQueue`.
    private let stateLock = DispatchQueue(label: "mic-capture.state")
    /// Serializes every (re)build so a user mic-switch and an in-flight route-change recovery can't
    /// race two `AVCaptureSession`s into existence. `startRunning`/`stopRunning` happen here, never
    /// under `stateLock`.
    private let configQueue = DispatchQueue(label: "mic-capture.config")

    private var session: AVCaptureSession?
    /// The device the USER chose (`nil` = system default). Set only on a *successful* start/switch, so
    /// a failed switch can't corrupt it. NEVER overwritten by a fallback, so we can re-pin to it when
    /// it reconnects.
    private var pinnedDeviceId: String?
    /// The device the active session is ACTUALLY capturing on (may be a fallback after a disconnect).
    /// Distinct from `pinnedDeviceId` so we know whether we're on a fallback and can re-pin. Keeps the
    /// `nil == system default` convention that mic_device provenance relies on.
    private var currentDeviceId: String?
    /// The CONCRETE device the running session is bound to (its `uniqueID`, non-nil while capturing) —
    /// distinct from `currentDeviceId`, which stays `nil` in default mode for provenance. The HAL
    /// device-change reevaluation compares against this to decide whether we are already on the device we
    /// SHOULD be on, so an unrelated device appearing (or a duplicate notification) is a no-op.
    private var currentConcreteDeviceId: String?
    private var isStopping = false
    private var isRecovering = false
    private var restartAttempts = 0
    private let maxRestartAttempts = 3

    /// Serial queue the Core Audio HAL property-listener block runs on (never the audio/main queue).
    private let monitorQueue = DispatchQueue(label: "mic-capture.device-monitor")
    /// The HAL listener block, retained so the SAME reference can be passed to remove it — Swift boxes a
    /// fresh block per call, so removal silently no-ops without the original reference.
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

    init(deliveryQueue: DispatchQueue, onSampleBuffer: @escaping (CMSampleBuffer) -> Void) {
        self.deliveryQueue = deliveryQueue
        self.onSampleBuffer = onSampleBuffer
    }

    deinit { stopDeviceMonitoring() }

    /// The device the active session is ACTUALLY capturing on (`nil` = system default), exposed so the
    /// service can record honest mic_device provenance at its own event-emission sites (`.captureStart`,
    /// `.micSwitch`) — a `buildAndStart` fallback updates this even when the requested id differs
    /// (council CONV-1, sibling of MIC-CURRENT-MISLABEL). Reads under the leaf `stateLock`.
    var resolvedDeviceId: String? { stateLock.sync { currentDeviceId } }

    /// Build and start the session for `deviceId` (`nil` = system default). Throws if the mic is
    /// unavailable or unauthorized, so `startCapture` can surface a clear, actionable error.
    func start(deviceId: String?) throws {
        stateLock.sync {
            isStopping = false
            isRecovering = false
            restartAttempts = 0
        }
        // `userInitiated` sets the pin atomically with the session swap (inside buildAndStart's stateLock
        // block), so a concurrent HAL reevaluation can never observe a fresh concrete device against a
        // stale pin (council MIC-HAL-RACE-2 / F2). A throw before the swap leaves the pin untouched.
        try configQueue.sync { try buildAndStart(deviceId: deviceId, userInitiated: true) }
        startDeviceMonitoring()
    }

    /// Stop capture and detach all observers. Idempotent.
    func stop() {
        let live: AVCaptureSession? = stateLock.sync {
            isStopping = true
            let s = session
            session = nil
            return s
        }
        stopDeviceMonitoring()
        live?.stopRunning()
    }

    /// Live mic switch (the mid-recording mic-switch dialog): retarget the session to a new device,
    /// reusing the same mic WAV so the file stays continuous. The pin moves only on success.
    func updateDevice(_ deviceId: String?) throws {
        // `userInitiated` moves the pin atomically with the concrete swap (see buildAndStart) so an
        // in-flight HAL reevaluation can't see a half-applied {pin, concrete} and switch back off the
        // device the user just picked (council MIC-HAL-RACE-2 / F2).
        try configQueue.sync { try buildAndStart(deviceId: deviceId, userInitiated: true) }
        stateLock.sync { restartAttempts = 0 }
    }

    // MARK: - Build

    /// MUST run on `configQueue` (callers wrap in `configQueue.sync`). Tears down any previous session
    /// and starts a fresh one capturing `deviceId`. Records the ACTUAL device in `currentDeviceId`.
    /// When `userInitiated` (a user start/switch, not a recovery), moves `pinnedDeviceId` to `deviceId`
    /// ATOMICALLY with the concrete swap so a concurrent HAL reevaluation never sees a half-applied
    /// {pin, concrete} (council MIC-HAL-RACE-2 / F2); recovery passes `false` so it never moves the pin.
    /// Throws `.stopped` if a stop raced in during the build, after tearing the new session down — so
    /// capture never leaks past stop.
    private func buildAndStart(deviceId: String?, userInitiated: Bool = false) throws {
        // Authorization is the #96 device-test risk: the helper captured the mic via ScreenCaptureKit
        // before, so its Microphone TCC grant may be implicit. Surface the status unambiguously, and
        // fail fast with an actionable error if it is hard-denied.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            Logger.audio.warning("Mic capture: audio authorization not determined in helper — proceeding")
        case .denied, .restricted:
            throw MicCaptureError.unauthorized
        @unknown default:
            break
        }

        // Resolve the device, tracking whether we actually got the REQUESTED one or fell back to the
        // system default. `resolvedId == nil` means "on the system default" — the convention the
        // disconnect/reconnect handlers rely on. Recording the requested id here even on a fallback
        // (the old bug) made re-pin and disconnect-recovery target a device that wasn't capturing, and
        // falsified mic_device provenance (council MIC-CURRENT-MISLABEL / REG-2).
        let device: AVCaptureDevice?
        let resolvedId: String?
        if let deviceId, let requested = AVCaptureDevice(uniqueID: deviceId) {
            device = requested
            resolvedId = deviceId
        } else {
            device = AVCaptureDevice.default(for: .audio)
            resolvedId = nil
        }
        guard let device else { throw MicCaptureError.noDevice }

        let newSession = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard newSession.canAddInput(input) else { throw MicCaptureError.cannotAddInput }
        newSession.addInput(input)

        let output = AVCaptureAudioDataOutput()
        guard newSession.canAddOutput(output) else { throw MicCaptureError.cannotAddOutput }
        output.setSampleBufferDelegate(self, queue: deliveryQueue)
        newSession.addOutput(output)

        // Swap the new session in and retire the old one. The swap is under stateLock (leaf); the
        // blocking stopRunning/startRunning are outside it.
        let old: AVCaptureSession? = stateLock.sync {
            let o = session
            session = newSession
            currentDeviceId = resolvedId
            currentConcreteDeviceId = device.uniqueID
            // Pin (the user's REQUESTED id, even on a fallback, so we re-pin when it returns) moves in the
            // SAME critical section as the concrete device — never observable half-applied.
            if userInitiated { pinnedDeviceId = deviceId }
            return o
        }
        old?.stopRunning()
        newSession.startRunning()

        // F1-style commit-or-abort: if a stop began while we were (re)building (stopRunning/startRunning
        // run outside stateLock), retire the just-started session instead of leaking a running capture
        // past stop.
        let raced: AVCaptureSession? = stateLock.sync {
            if isStopping { session = nil; return newSession }
            return nil
        }
        if let raced {
            raced.stopRunning()
            throw MicCaptureError.stopped
        }

        Logger.audio.info("Mic capture started — device: \(device.localizedName, privacy: .public) (\(resolvedId ?? "default", privacy: .public))")
    }

    // MARK: - Device-change monitoring (Core Audio HAL)

    private static let deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Start monitoring for audio-device changes. AVFoundation's `wasDisconnected`/`wasConnected`
    /// notifications and KVO on `isConnected` do NOT fire for audio-input removal on macOS — the session
    /// just goes silent (gotcha #55 / `docs/mic-capture-design.md`). So the route-change signal comes from
    /// the Core Audio HAL: a property listener on the system object for `kAudioHardwarePropertyDefaultInputDevice`
    /// (the default input flipped — AirPods in/out, drives auto-follow) and `kAudioHardwarePropertyDevices`
    /// (a device appeared/vanished — drives pinned fallback/re-pin). Both feed one debounced reevaluation.
    /// `runtimeErrorNotification` is kept as a belt-and-suspenders fallback for a session that errors outright.
    private func startDeviceMonitoring() {
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification, object: nil
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleDeviceReevaluation()
        }
        // Claim the block under stateLock (a leaf, no call-out) so a concurrent stopDeviceMonitoring can't
        // race the add/remove on `deviceListenerBlock` (council MIC-HAL-RACE-1). The HAL Add calls happen
        // OUTSIDE the lock so the leaf-lock no-call-out invariant holds.
        let shouldRegister: Bool = stateLock.sync {
            guard deviceListenerBlock == nil else { return false }
            deviceListenerBlock = block
            return true
        }
        guard shouldRegister else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)  // imported as Int32 — must cast
        var devices = Self.deviceListAddress
        var defaultInput = Self.defaultInputAddress
        let s1 = AudioObjectAddPropertyListenerBlock(system, &devices, monitorQueue, block)
        let s2 = AudioObjectAddPropertyListenerBlock(system, &defaultInput, monitorQueue, block)
        if s1 != noErr || s2 != noErr {
            // Registration failure means we silently lose ALL device-following (auto-follow, fallback,
            // re-pin) — exactly the silent-mic-death class this exists to prevent — so surface it into the
            // anomaly ring, not just the log (council hal-listener-registration-failure-not-surfaced).
            Logger.audio.error("Mic device monitor: HAL listener registration failed (\(s1), \(s2))")
            onEvent?(.streamStopError, .anomaly, ["source": "mic", "reason": "device monitor unavailable",
                                                  "status": "\(s1)/\(s2)"])
        }
    }

    /// Detach the HAL listener + the runtime-error observer. Idempotent.
    private func stopDeviceMonitoring() {
        NotificationCenter.default.removeObserver(self)
        // Read-and-nil the block in ONE leaf-lock critical section so two concurrent stop()s (e.g. an XPC
        // invalidation racing a user stopCapture) can't tear the ARC optional closure (council
        // MIC-HAL-RACE-1). The HAL Remove calls run OUTSIDE the lock using the claimed reference.
        let block: AudioObjectPropertyListenerBlock? = stateLock.sync {
            let b = deviceListenerBlock
            deviceListenerBlock = nil
            return b
        }
        guard let block else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devices = Self.deviceListAddress
        var defaultInput = Self.defaultInputAddress
        _ = AudioObjectRemovePropertyListenerBlock(system, &devices, monitorQueue, block)
        _ = AudioObjectRemovePropertyListenerBlock(system, &defaultInput, monitorQueue, block)
    }

    /// Debounce a burst of HAL notifications (a single route change fires several) and let the new route
    /// settle before re-targeting. Runs on `monitorQueue`.
    private func scheduleDeviceReevaluation() {
        monitorQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.reevaluateDevices() }
    }

    /// Re-target the mic to the device we SHOULD be on after a device change: the user's pinned device if
    /// it is still present, otherwise the current system default (auto-follow — the user never has to pick
    /// a mic; we track whatever macOS considers correct for the active route). Rebuilds ONLY when that
    /// differs from the concrete device we are actually on, so connecting an unrelated device or a duplicate
    /// notification is a no-op. This single rule covers disconnect-fallback, reconnect-re-pin, and
    /// default-following uniformly. Runs on `monitorQueue`.
    private func reevaluateDevices() {
        let (pinned, concrete, stopping, recovering) = stateLock.sync {
            (pinnedDeviceId, currentConcreteDeviceId, isStopping, isRecovering)
        }
        if stopping { return }
        if recovering {
            // A rebuild is already in flight; re-check shortly so a change landing during it isn't missed.
            scheduleDeviceReevaluation()
            return
        }

        // "Be on the pinned device if available, else follow the system default" — the pure rule, so it's
        // unit-tested without hardware (see MicTargeting + MicTargetingTests).
        let available = Set(AudioDeviceEnumerator.availableDevices().compactMap { $0.id })
        let systemDefault = AVCaptureDevice.default(for: .audio)?.uniqueID
        let decision = MicTargeting.decide(
            pinned: pinned, current: concrete, available: available, systemDefault: systemDefault
        )
        guard decision.needsSwitch else { return }  // already on the right device

        // If the device we are LEAVING has vanished, that is a genuine input loss — flag it as an anomaly
        // so the session's forensic .diag.jsonl is written (#95). A change while our device is still present
        // (e.g. AirPods connected and became the new default) is an intentional follow, captured by the
        // .restartInPlace the recovery records on success — not an anomaly.
        if decision.leavingDeviceGone {
            Logger.audio.warning("Mic input removed — was \(concrete ?? "none", privacy: .public), following to \(decision.target ?? "default", privacy: .public)")
            onEvent?(.streamStopError, .anomaly, ["source": "mic", "reason": "input device removed",
                                                  "from": concrete ?? "none", "to": decision.target ?? "default"])
        } else {
            Logger.audio.info("Mic following device change — \(concrete ?? "none", privacy: .public) → \(decision.target ?? "default", privacy: .public)")
        }
        // A device change is fresh information: refresh the recovery budget so a prior exhaustion can't
        // block following the new device (council F3).
        stateLock.sync { restartAttempts = 0 }
        // recoverLoop recomputes its target from fresh state each iteration (so a mid-recovery user pin is
        // honored) — no frozen decision is passed across the async hop (council MIC-FOLLOW-PIN-OVERRIDE).
        attemptRecover()
    }

    @objc private func handleRuntimeError(_ note: Notification) {
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
        Logger.audio.error("Mic capture runtime error: \(err?.localizedDescription ?? "unknown", privacy: .public)")
        onEvent?(.streamStopError, .anomaly, ["source": "mic", "error": err?.localizedDescription ?? "unknown"])
        attemptRecover()
    }

    /// Kick off a recovery loop on a background queue, at most one at a time.
    private func attemptRecover() {
        let shouldStart: Bool = stateLock.sync {
            if isStopping || isRecovering { return false }
            isRecovering = true
            return true
        }
        guard shouldStart else { return }
        DispatchQueue.global(qos: .userInitiated).async { self.recoverLoop() }
    }

    private func recoverLoop() {
        defer { stateLock.sync { isRecovering = false } }
        while true {
            let (stopping, attempts, pinned) = stateLock.sync { (isStopping, restartAttempts, pinnedDeviceId) }
            if stopping { return }
            if attempts >= maxRestartAttempts {
                Logger.audio.error("Mic recovery budget exhausted — mic unavailable, system audio continues")
                // Clear the concrete device we are no longer capturing on, so a LATER HAL event — the very
                // device reconnecting, or a new default appearing — is seen by reevaluateDevices as
                // needsSwitch (current==nil ⇒ leavingDeviceGone, target!=nil ⇒ needsSwitch) and rebuilds.
                // Without this the stale concrete makes us think we're already on the right device and the
                // mic stays silently dead — fatal on Macs with no built-in fallback (council F1).
                stateLock.sync { currentConcreteDeviceId = nil }
                // The service's onUnavailable handler records the .restartFailed anomaly; don't also
                // record it here (that would double-count the event).
                onUnavailable?("mic restart budget exhausted")
                return
            }
            // Recompute the target from FRESH state every iteration: the pinned device if it is currently
            // available, else the system default (nil). Never a frozen forceDefault — so a pin the user
            // applies mid-recovery, or a device that comes/goes during the loop, is honored on the next
            // pass (council MIC-FOLLOW-PIN-OVERRIDE / mic-switch-clobbered-by-autofollow-recovery).
            let available = Set(AudioDeviceEnumerator.availableDevices().compactMap { $0.id })
            let deviceId = MicTargeting.recoveryTarget(pinned: pinned, available: available)
            do {
                try configQueue.sync { try buildAndStart(deviceId: deviceId) }
                // Report the RESOLVED device, not the requested one: buildAndStart may have fallen back
                // to the system default if the pinned device couldn't be opened, and this event feeds
                // mic_device provenance. Reporting `deviceId` here would falsify provenance on a silent
                // fallback (council PROV-RECOVER-REQID — sibling of MIC-CURRENT-MISLABEL). buildAndStart
                // set currentDeviceId under this same lock; if a concurrent user switch updated it first,
                // reporting the actually-current device is still exactly what mic_device wants.
                let (resolved, concrete) = stateLock.sync { () -> (String?, String?) in
                    restartAttempts = 0
                    return (currentDeviceId, currentConcreteDeviceId)
                }
                Logger.audio.info("Mic capture recovered in place — device: \(resolved ?? "default", privacy: .public)")
                // `mic` keeps the nil==default provenance convention; `device` records the CONCRETE physical
                // mic we actually followed to, so a clean auto-follow (built-in → AirPods, both present) still
                // leaves the followed-to identity in the forensic trail (council AUTOFOLLOW-CONCRETE-UNRECORDED).
                onEvent?(.restartInPlace, .warning, ["source": "mic", "mic": resolved ?? "default",
                                                     "device": concrete ?? "unknown"])
                onRecovered?(resolved)
                return
            } catch MicCaptureError.stopped {
                // A stop raced in; buildAndStart already retired the new session. Nothing to recover.
                return
            } catch {
                stateLock.sync { restartAttempts += 1 }
                Logger.audio.error("Mic recovery attempt failed: \(error, privacy: .public)")
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    /// Delivered on `deliveryQueue` (the capture service's audio queue). Forward the mic buffer to the
    /// handler, which converts + appends it under the single-writer-queue invariant.
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSampleBuffer(sampleBuffer)
    }
}

enum MicCaptureError: LocalizedError {
    case unauthorized
    case noDevice
    case cannotAddInput
    case cannotAddOutput
    case stopped

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Microphone access denied — grant Microphone access in System Settings"
        case .noDevice:
            return "No microphone available"
        case .cannotAddInput:
            return "Could not attach the microphone input"
        case .cannotAddOutput:
            return "Could not attach the microphone output"
        case .stopped:
            return "Microphone capture stopped during setup"
        }
    }
}
