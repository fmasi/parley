import Foundation

/// The capture helper's error replies that the app acts on, shared by both sides (H2 council, B-I3).
/// In TranscriberCore rather than AudioCaptureProtocol: the helper and the app both depend on it,
/// and so does `RecordingCoordinator`. Match them exactly.
public enum CaptureReplies {
    /// Nothing is capturing (stop, rotate, mic switch). On a rotate, the app's dead-capture signal (§8.7).
    public static let noCaptureInProgress = "No capture in progress"
    /// A rotate refused because the capture is starting or stopping: refused, NOT dead, so an ordinary
    /// Stop racing the rotation timer never takes the crash path. Also the reply to a duplicate stop
    /// while a stop is already under way. Never contains `noCaptureInProgress`.
    public static let refusedStopping = "Refused: capture is starting or stopping"
}
