import Foundation

/// XPC protocol for communication between the SwiftUI app and the audio capture service.
/// Both the app target and the XPC service target import this.
@objc public protocol AudioCaptureProtocol {
    /// Start capturing system audio + microphone to WAV files in the given directory.
    /// Reply: (success: Bool, errorMessage: String?)
    func startCapture(
        outputDirectory: String,
        baseName: String,
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
}

/// The XPC service name — must match the bundle identifier in the XPC service's Info.plist.
public let audioCaptureServiceName = "com.audio-transcribe.capture-helper"
