import Foundation

/// Pure judgement of the crash-relaunch LaunchAgent (L11). `isInstalled()` used to mean "the plist
/// file exists"; launchd's opinion is what relaunches the app, so the job must be LOADED and must
/// point at the binary that is running.
public enum LaunchAgentHealth {
    public enum State: Equatable, Sendable {
        case healthy
        case missing
        case stalePath(found: String)
        case notLoaded
    }

    public enum Action: Equatable, Sendable {
        case none
        case installAndBootstrap
        case rewriteAndBootstrap
        case bootstrap
    }

    public static func assess(plistProgramPath: String?, executablePath: String, loaded: Bool) -> State {
        guard let plistProgramPath else { return .missing }
        if plistProgramPath != executablePath { return .stalePath(found: plistProgramPath) }
        return loaded ? .healthy : .notLoaded
    }

    public static func action(for state: State) -> Action {
        switch state {
        case .healthy: return .none
        case .missing: return .installAndBootstrap
        case .stalePath: return .rewriteAndBootstrap
        case .notLoaded: return .bootstrap
        }
    }

    /// The sticky row's text; nil when there is nothing to say.
    public static func userMessage(for state: State) -> String? {
        switch state {
        case .healthy: return nil
        case .missing, .notLoaded, .stalePath:
            return "Crash protection is off — if Parley crashes mid-recording it will not relaunch. Quit and reopen Parley to repair it."
        }
    }

    /// Log-safe name: `stalePath` carries a filesystem path, which is never logged `.public`.
    public static func logName(for state: State) -> String {
        switch state {
        case .healthy: return "healthy"
        case .missing: return "missing"
        case .stalePath: return "stalePath"
        case .notLoaded: return "notLoaded"
        }
    }
}
