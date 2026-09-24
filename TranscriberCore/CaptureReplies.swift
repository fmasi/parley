import Foundation

/// The capture helper's replies that the app acts on, shared by both sides (H2 council, B-I3; round 2
/// items 1, 2, 6). In TranscriberCore rather than AudioCaptureProtocol: the helper and the app both
/// depend on it, and so does `RecordingCoordinator`. Match them exactly, by these constants.
public enum CaptureReplies {
    /// Nothing is capturing (stop, rotate, mic switch). On a rotate, the app's dead-capture signal (§8.7).
    public static let noCaptureInProgress = "No capture in progress"
    /// A rotate refused because the capture is starting or stopping: refused, NOT dead, so an ordinary
    /// Stop racing the rotation timer never takes the crash path. Also the reply to a duplicate stop
    /// while a stop is already under way, and to a rotate that lost its session to a stop.
    public static let refusedStopping = "Refused: capture is starting or stopping"
    /// `startCapture` while a start or a capture is already in flight (unchanged wire string).
    public static let alreadyInProgress = "Capture already in progress"
    /// `startCapture`'s reply when a stop or disconnect arrived during it: it tore down what it built.
    public static let cancelledWhileStarting = "Capture cancelled — stopped while starting"
    /// `startCapture`'s reply when it did not finish within its own deadline and was abandoned.
    public static let startTimedOut = "Capture start timed out"
    /// `stopCapture`'s reply when that stop arrived during a start that then ended (aborted, failed or
    /// timed out): nothing was recorded, the files are gone, the session is free.
    public static let startCancelled = "Capture start cancelled"
}
