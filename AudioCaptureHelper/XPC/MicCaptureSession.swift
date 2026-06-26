import AVFoundation
import Foundation
import os
import TranscriberCore

/// Captures the microphone via `AVCaptureSession` + `AVCaptureAudioDataOutput`, decoupled from the
/// system-audio `SCStream` (#96).
///
/// Why this exists: previously ONE `SCStream` captured both system audio and the mic, so any mic
/// route change (AirPods connect/disconnect, HFP↔A2DP) stopped the whole stream — the root cause of
/// the "recording crashed mid-call, lost minutes" incidents. With the mic on its own
/// `AVCaptureSession`, a mic route change can no longer tear down system-audio capture; this session
/// recovers the mic on its own (fall back + re-pin) while system audio keeps recording uninterrupted.
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
    /// the pinned (or fallback) device — surfaced as the calm "Recording Resumed" notice. No audio is
    /// lost beyond the brief switch gap; the same mic WAV continues.
    var onRecovered: (() -> Void)?
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
    /// Distinct from `pinnedDeviceId` so we know whether we're on a fallback and can re-pin.
    private var currentDeviceId: String?
    private var isStopping = false
    private var isRecovering = false
    private var restartAttempts = 0
    private let maxRestartAttempts = 3

    init(deliveryQueue: DispatchQueue, onSampleBuffer: @escaping (CMSampleBuffer) -> Void) {
        self.deliveryQueue = deliveryQueue
        self.onSampleBuffer = onSampleBuffer
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Build and start the session for `deviceId` (`nil` = system default). Throws if the mic is
    /// unavailable or unauthorized, so `startCapture` can surface a clear, actionable error.
    func start(deviceId: String?) throws {
        stateLock.sync {
            isStopping = false
            isRecovering = false
            restartAttempts = 0
        }
        try configQueue.sync { try buildAndStart(deviceId: deviceId) }
        // Pin the user's choice only AFTER a successful start so a throw can't leave a stale pin.
        stateLock.sync { pinnedDeviceId = deviceId }
        observeRouteChanges()
    }

    /// Stop capture and detach all observers. Idempotent.
    func stop() {
        let live: AVCaptureSession? = stateLock.sync {
            isStopping = true
            let s = session
            session = nil
            return s
        }
        NotificationCenter.default.removeObserver(self)
        live?.stopRunning()
    }

    /// Live mic switch (the mid-recording mic-switch dialog): retarget the session to a new device,
    /// reusing the same mic WAV so the file stays continuous. The pin moves only on success.
    func updateDevice(_ deviceId: String?) throws {
        try configQueue.sync { try buildAndStart(deviceId: deviceId) }
        stateLock.sync {
            pinnedDeviceId = deviceId
            restartAttempts = 0
        }
    }

    // MARK: - Build

    /// MUST run on `configQueue` (callers wrap in `configQueue.sync`). Tears down any previous session
    /// and starts a fresh one capturing `deviceId`. Records the ACTUAL device in `currentDeviceId`;
    /// does NOT touch `pinnedDeviceId` (callers own the user's pin). Throws `.stopped` if a stop raced
    /// in during the build, after tearing the new session down — so capture never leaks past stop.
    private func buildAndStart(deviceId: String?) throws {
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

        let device: AVCaptureDevice? = {
            if let deviceId, let pinned = AVCaptureDevice(uniqueID: deviceId) { return pinned }
            return AVCaptureDevice.default(for: .audio)
        }()
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
            currentDeviceId = deviceId
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

        Logger.audio.info("Mic capture started — device: \(device.localizedName, privacy: .public) (\(deviceId ?? "default", privacy: .public))")
    }

    // MARK: - Route-change recovery

    private func observeRouteChanges() {
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDeviceDisconnected(_:)),
            name: AVCaptureDevice.wasDisconnectedNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDeviceConnected(_:)),
            name: AVCaptureDevice.wasConnectedNotification, object: nil
        )
    }

    @objc private func handleRuntimeError(_ note: Notification) {
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
        Logger.audio.error("Mic capture runtime error: \(err?.localizedDescription ?? "unknown", privacy: .public)")
        onEvent?(.streamStopError, .anomaly, ["source": "mic", "error": err?.localizedDescription ?? "unknown"])
        attemptRecover(forceDefault: false)
    }

    @objc private func handleDeviceDisconnected(_ note: Notification) {
        guard let device = note.object as? AVCaptureDevice, device.hasMediaType(.audio) else { return }
        let (current, stopping) = stateLock.sync { (currentDeviceId, isStopping) }
        guard !stopping else { return }
        // Only react if the device we are ACTUALLY capturing on went away. If a specific device was in
        // use and it vanished, fall back to the system default; if we were on default, rebuild (the
        // default has already moved to a surviving device).
        let weWereUsingIt = (current == device.uniqueID) || (current == nil)
        guard weWereUsingIt else { return }
        Logger.audio.warning("Mic device disconnected: \(device.localizedName, privacy: .public) — recovering")
        onEvent?(.streamStopError, .anomaly, ["source": "mic", "reason": "device disconnected", "device": device.localizedName])
        attemptRecover(forceDefault: current == device.uniqueID)
    }

    @objc private func handleDeviceConnected(_ note: Notification) {
        guard let device = note.object as? AVCaptureDevice, device.hasMediaType(.audio) else { return }
        let (pinned, current, stopping) = stateLock.sync { (pinnedDeviceId, currentDeviceId, isStopping) }
        // Re-pin only when the user's originally-chosen device reappears AND we are currently on a
        // fallback (current != pinned). Otherwise a reconnect of some unrelated device is irrelevant.
        guard !stopping, let pinned, device.uniqueID == pinned, current != pinned else { return }
        Logger.audio.info("Pinned mic reconnected: \(device.localizedName, privacy: .public) — re-pinning")
        onEvent?(.micSwitch, .info, ["mic": pinned, "reason": "reconnect"])
        attemptRecover(forceDefault: false)
    }

    /// Kick off a recovery loop on a background queue, at most one at a time.
    private func attemptRecover(forceDefault: Bool) {
        let shouldStart: Bool = stateLock.sync {
            if isStopping || isRecovering { return false }
            isRecovering = true
            return true
        }
        guard shouldStart else { return }
        DispatchQueue.global(qos: .userInitiated).async { self.recoverLoop(forceDefault: forceDefault) }
    }

    private func recoverLoop(forceDefault: Bool) {
        defer { stateLock.sync { isRecovering = false } }
        while true {
            let (stopping, attempts, pinned) = stateLock.sync { (isStopping, restartAttempts, pinnedDeviceId) }
            if stopping { return }
            if attempts >= maxRestartAttempts {
                Logger.audio.error("Mic recovery budget exhausted — mic unavailable, system audio continues")
                // The service's onUnavailable handler records the .restartFailed anomaly; don't also
                // record it here (that would double-count the event).
                onUnavailable?("mic restart budget exhausted")
                return
            }
            let deviceId = forceDefault ? nil : pinned
            do {
                try configQueue.sync { try buildAndStart(deviceId: deviceId) }
                stateLock.sync { restartAttempts = 0 }
                Logger.audio.info("Mic capture recovered in place — device: \(deviceId ?? "default", privacy: .public)")
                onEvent?(.restartInPlace, .warning, ["source": "mic", "mic": deviceId ?? "default"])
                onRecovered?()
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
