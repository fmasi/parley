import Foundation

/// XPC protocol for communication between the SwiftUI app and the audio capture service.
/// Both the app target and the XPC service target import this.
@objc public protocol AudioCaptureProtocol {
    /// Start capturing system audio + microphone to WAV files in the given directory.
    /// `microphoneDeviceId` selects a specific mic (AVCaptureDevice.uniqueID);
    /// pass nil to use the system default input device.
    /// `systemAudioSource` is the `SystemAudioSource` raw value ("sck" | "core_audio_tap") selecting
    /// the system-audio capture mechanism (#103); an unrecognized value falls back to SCK.
    /// Reply: (success: Bool, errorMessage: String?)
    func startCapture(
        outputDirectory: String,
        baseName: String,
        microphoneDeviceId: String?,
        systemAudioSource: String,
        reply: @escaping (Bool, String?) -> Void
    )

    /// Stop the current capture session and finalize WAV files.
    /// Reply: (systemAudioPath: String?, micAudioPath: String?, errorMessage: String?)
    /// Both paths are non-nil on success; errorMessage is non-nil on failure.
    func stopCapture(
        reply: @escaping (String?, String?, String?) -> Void
    )

    /// Query whether a capture session is currently active.
    /// Reply: (isCapturing: Bool, errorMessage: String?)
    func status(
        reply: @escaping (Bool, String?) -> Void
    )

    /// Update the microphone device on a live capture session.
    /// Pass nil to switch back to the system default input device.
    /// Reply: (success: Bool, errorMessage: String?)
    func updateMicrophone(
        deviceId: String?,
        reply: @escaping (Bool, String?) -> Void
    )

    /// Rotate the current WAV output files to new paths, returning the old paths.
    /// Used for chunk recording — seals the current chunk and starts writing to new files.
    /// Reply: (oldSystemPath: String?, oldMicPath: String?, errorMessage: String?)
    func rotateChunk(
        outputDirectory: String,
        newBaseName: String,
        reply: @escaping (String?, String?, String?) -> Void
    )

    /// Drain and clear the helper's anomaly-gated diagnostic ring (#95).
    /// Reply: JSON-encoded `[CaptureEvent]` (helper origin), or nil if empty/unavailable.
    func drainDiagnostics(
        reply: @escaping (Data?) -> Void
    )
}

/// Reverse XPC channel: the helper calls back into the app to report that it self-healed a benign
/// stream stop in place, or that capture has terminally failed (#86). The app sets an exported
/// object conforming to this so a route-change restart surfaces as a transient "Recording Resumed"
/// notice instead of a crash, and a fatal stop stops the session cleanly.
@objc public protocol AudioCaptureClientProtocol {
    /// The SCStream stopped (benign route change) and was restarted in place — no audio lost.
    func captureDidRestartInPlace()
    /// Capture failed and could not be restarted within budget; the session must stop.
    func captureDidFailFatally(reason: String)
    /// The MID-RECORDING system (remote) stream could not be restarted within budget (#86). The mic
    /// keeps recording on its own AVCaptureSession — the recording is NOT stopped, only a "mic only"
    /// warning is surfaced.
    func captureSystemAudioUnrecoverable(reason: String)
    /// The mic auto-switched to a new device — `deviceId` is the new device UID (nil = system default).
    @objc optional func micDeviceChanged(to deviceId: String?)
}

/// The XPC service name — must match the bundle identifier in the XPC service's Info.plist.
public let audioCaptureServiceName = "eu.fmasi.parley.capture-helper"
