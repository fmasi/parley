import Foundation

/// Elapsed-recording formatting for the menu bar panel's live timer.
///
/// Lives in Core rather than the app target so it is reachable from the test
/// suite: it is a pure function with real boundary cases (the minute and hour
/// rollovers), not view code.
///
/// "mm:ss" under an hour, "h:mm:ss" at an hour and above. Monospaced-digit
/// friendly. Times before `start` clamp to zero rather than counting backwards.
public func recordingTimerString(from start: Date, to now: Date) -> String {
    let total = max(0, Int(now.timeIntervalSince(start)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
}
