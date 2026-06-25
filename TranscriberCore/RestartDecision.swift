import Foundation

/// Decides how the capture service should react to an SCStream stop (`didStopWithError`).
///
/// A benign device/route change (e.g. AirPods connect) stops the stream but is recoverable
/// in place; an explicit user stop or an already-inactive service should be left alone; and a
/// stream that keeps failing past its restart budget is a genuine fatal fault (#86).
public enum RestartDecision: Equatable {
    /// Do nothing — the stop is expected (user stopped) or capture is already inactive.
    case ignore
    /// Restart the stream in place (transient device/route change).
    case restart
    /// Give up and surface a fatal failure (restart budget exhausted).
    case failFatal

    /// - Parameters:
    ///   - isUserStopped: true if the stop came from an explicit stop request.
    ///   - isCapturing: whether the service still considers itself recording.
    ///   - attempts: number of in-place restarts already performed this session.
    ///   - maxAttempts: restart budget before declaring a fatal failure.
    public static func evaluate(
        isUserStopped: Bool,
        isCapturing: Bool,
        attempts: Int,
        maxAttempts: Int
    ) -> RestartDecision {
        if isUserStopped || !isCapturing { return .ignore }
        return attempts < maxAttempts ? .restart : .failFatal
    }
}
