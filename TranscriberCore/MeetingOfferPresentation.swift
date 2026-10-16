import Foundation

/// The words on a meeting-sensing offer (#118). Pure, so the copy that carries the product's privacy
/// promise is pinned by tests — `MeetingPromptPresenter`, which shows it, lives in the app target and
/// is compile-checked only.
public enum MeetingOfferText {
    public static let startTitle = "Record this meeting?"
    public static let stopTitle = "Stop recording?"

    /// The first offer a user ever sees carries the disclosure instead of the description (spec D6):
    /// the feature is default-on, so the moment it first acts is the moment it must explain itself.
    public static func startSubtitle(app: MeetingApp, firstEver: Bool) -> String {
        firstEver
            ? "Parley noticed \(app.displayName) using the mic — it only checks which app, on this Mac, and never listens."
            : "\(app.displayName) is using the microphone"
    }

    /// Once a calendar title is known it replaces the description — but never the disclosure.
    public static func startSubtitle(calendarTitle: String, app: MeetingApp) -> String {
        "\(calendarTitle) · \(app.displayName)"
    }

    public static func stopSubtitle(app: MeetingApp, sessionName: String) -> String {
        "\(app.displayName) released the microphone · \(sessionName)"
    }
}

/// Store for a one-shot UI flag. `UserDefaults` already has exactly this shape, so it conforms as-is;
/// tests inject their own.
public protocol OneShotFlagStore: AnyObject {
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
}

extension UserDefaults: OneShotFlagStore {}

/// The default-on feature has to explain itself the first time it ever acts (spec D6) — and exactly
/// once. The "once, ever" part is policy worth testing, so it lives here rather than as two
/// `UserDefaults` lines inside the presenter.
public enum MeetingDisclosure {
    public static let shownKey = "meeting_sensing_disclosure_shown"

    /// True for the first caller ever (recording the fact), false for every caller after it.
    @discardableResult
    public static func consumeFirstShowing(store: OneShotFlagStore) -> Bool {
        guard !store.bool(forKey: shownKey) else { return false }
        store.set(true, forKey: shownKey)
        return true
    }
}

/// What to do with a start the user asked for while the previous recording was still transcribing.
public enum QueuedStartDecision: Equatable, Sendable {
    /// Not yet — the app is still busy (or nothing is queued).
    case wait
    /// The call ended before the app was free: drop it and clear the banner.
    case drop
    case start(MeetingApp)
}

/// `AppState` has one phase, so a Record chosen while the previous meeting is still transcribing has
/// to wait for idle (spec §4). The wait is the reason this needs a rule of its own: by the time the
/// app is free the call may be over, and starting then would record an empty room.
public enum MeetingQueuedStart {
    public static func decide(
        queued: MeetingApp?, isIdle: Bool, capturing: Set<MeetingApp>
    ) -> QueuedStartDecision {
        guard let queued, isIdle else { return .wait }
        return capturing.contains(queued) ? .start(queued) : .drop
    }
}
