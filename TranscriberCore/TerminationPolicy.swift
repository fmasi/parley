import Foundation

/// How the app is being asked to end (L10 review 53).
public enum TerminationKind: Equatable, Sendable {
    /// Parley's own Quit: already confirmed, its recording already stopped (bounded, ≤ 30 s) before it asked.
    case userQuit
    /// Logout, shutdown or restart: the quit Apple event carries the reason, or `willPowerOff` was seen.
    case powerOff
    /// Anyone else: Activity Monitor, `osascript -e 'quit app "Parley"'`, Sparkle's relaunch to update.
    case outsideQuit
}

/// The answer to `applicationShouldTerminate` (L10 review 53), pure so every kind of termination is tested.
/// A power-off or an outside quit arrives with no warning and the process ends right after the answer: while
/// Parley has work in flight it answers "later", stops the helper within a TIGHT bound (so it seals its files),
/// leaves the sentinel marked stopping, skips the long finalize — the next launch salvages it — and then lets
/// the app go. Parley's own Quit did all of that (with the user's confirmation) before asking, so it ends at once.
public enum TerminationPolicy {
    public enum Reply: Equatable, Sendable {
        case terminateNow
        case terminateLater(bound: Duration)
    }

    /// A logout or shutdown must not be held: loginwindow gives up on an app that does not answer.
    public static let terminationBound: Duration = .seconds(5)
    /// Parley's own Quit: the user confirmed it and sees it happen; the stop (and what it can finish of the
    /// transcript) is bounded at this (`RecordingCoordinator.quitStopBound`).
    public static let userQuitBound: Duration = .seconds(30)

    /// What an exit would cut short: a recording, a start or a stop in flight, a transcript being finished,
    /// or a crash recovery.
    public static func isBusy(recording: Bool, startInFlight: Bool, stopInFlight: Bool, transcribing: Bool,
                              recoveryInFlight: Bool) -> Bool {
        recording || startInFlight || stopInFlight || transcribing || recoveryInFlight
    }

    public static func reply(busy: Bool, kind: TerminationKind) -> Reply {
        guard busy else { return .terminateNow }
        switch kind {
        case .userQuit: return .terminateNow
        case .powerOff, .outsideQuit: return .terminateLater(bound: terminationBound)
        }
    }

    /// The quit Apple event's reasons (`keyAEQuitReason`) that mean a logout, restart or shutdown:
    /// kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown.
    static let powerOffReasons: Set<FourCharCode> = Set(["logo", "rlgo", "rrst", "rsdn", "rest", "shut"].map(fourCharCode))

    /// How long a `willPowerOff` counts (L review 107): a logout that was CANCELLED sends no second notice, so a
    /// later quit must not still be read as a power-off.
    public static let powerOffWindow: TimeInterval = 60

    /// Which kind of termination this is (L review 107). The quit event's own reason is the authority: a logout,
    /// restart or shutdown there is a power-off whatever else was asked. Then Parley's own Quit is the user's —
    /// even just after a logout the user cancelled. Only then does a recent `willPowerOff` (within
    /// `powerOffWindow`) make it a power-off; anything else is a quit from outside Parley.
    public static func kind(quitReason: FourCharCode?, powerOffSeenAt: Date?, now: Date, userQuitRequested: Bool) -> TerminationKind {
        if quitReason.map(powerOffReasons.contains) == true { return .powerOff }
        if userQuitRequested { return .userQuit }
        if let seen = powerOffSeenAt, now.timeIntervalSince(seen) <= powerOffWindow { return .powerOff }
        return .outsideQuit
    }

    private static func fourCharCode(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
