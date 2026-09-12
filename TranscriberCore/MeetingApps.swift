import Foundation

/// A meeting-capable app family. Helpers (`com.google.Chrome.helper`, `us.zoom.xos.helper`) resolve to
/// the family the user sees, so one call never looks like two apps.
public struct MeetingApp: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A dedicated conferencing app — high confidence that mic use means a call.
        case native
        /// A browser — lower confidence (dictation, voice search). Prompts once, then the cooldown.
        case browser
    }
    public let id: String
    public let displayName: String
    public let kind: Kind

    public init(id: String, displayName: String, kind: Kind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }
}

/// Reviewable data: which bundle IDs count as "a meeting app is using the microphone".
/// FaceTime is deliberately absent (personal calls, #118). Unknown IDs never prompt — precision over
/// recall, since a wrong prompt is the thing that makes users turn the feature off.
public enum MeetingApps {
    /// Parley itself: the app (level meters) and the XPC capture helper. Never classified.
    public static let ownPrefix = "eu.fmasi.parley"

    static let zoom    = MeetingApp(id: "us.zoom.xos",              displayName: "Zoom",    kind: .native)
    static let teams   = MeetingApp(id: "com.microsoft.teams2",     displayName: "Teams",   kind: .native)
    static let webex   = MeetingApp(id: "com.cisco.webexmeetingsapp", displayName: "Webex", kind: .native)
    static let discord = MeetingApp(id: "com.hnc.Discord",          displayName: "Discord", kind: .native)
    static let slack   = MeetingApp(id: "com.tinyspeck.slackmacgap", displayName: "Slack",  kind: .native)
    static let chrome  = MeetingApp(id: "com.google.Chrome",        displayName: "Chrome",  kind: .browser)
    static let safari  = MeetingApp(id: "com.apple.Safari",         displayName: "Safari",  kind: .browser)
    static let arc     = MeetingApp(id: "company.thebrowser.Browser", displayName: "Arc",   kind: .browser)
    static let edge    = MeetingApp(id: "com.microsoft.edgemac",    displayName: "Edge",    kind: .browser)
    static let firefox = MeetingApp(id: "org.mozilla.firefox",      displayName: "Firefox", kind: .browser)

    /// (family prefix, app). A bundle ID matches a row when it equals the prefix or starts with
    /// `prefix + "."` — so `us.zoom.xos.helper` is Zoom but `us.zoomfoo` is not.
    ///
    /// Rows marked `TODO(Task 0)` were written from the spec, not from a device: the on-device spike
    /// that reads the bundle IDs Core Audio actually reports for a process holding the mic has not run
    /// yet. Browsers and Zoom/Teams route audio through helper processes whose exact IDs must be
    /// confirmed (and any missing helper added) before this table can be trusted in the field.
    static let families: [(prefix: String, app: MeetingApp)] = [
        ("us.zoom", zoom),                       // TODO(Task 0): verify on device
        ("com.microsoft.teams", teams),          // classic + its helpers — TODO(Task 0): verify on device
        // New Teams needs its own row: the match rule wants the prefix or a dot after it, and the "2"
        // is neither — "com.microsoft.teams" alone never reaches "com.microsoft.teams2".
        ("com.microsoft.teams2", teams),         // new Teams + its helpers — TODO(Task 0): verify on device
        ("com.cisco.webexmeetingsapp", webex),
        ("com.webex.meetingmanager", webex),
        ("com.hnc.Discord", discord),
        ("com.tinyspeck.slackmacgap", slack),
        ("com.google.Chrome", chrome),           // TODO(Task 0): verify on device
        // Safari/WebKit media runs in the GPU process, which carries no Safari identity of its own.
        ("com.apple.WebKit.GPU", safari),        // TODO(Task 0): verify on device
        ("com.apple.Safari", safari),            // TODO(Task 0): verify on device
        ("company.thebrowser.Browser", arc),     // TODO(Task 0): verify on device
        ("com.microsoft.edgemac", edge),         // TODO(Task 0): verify on device
        ("org.mozilla.firefox", firefox),        // TODO(Task 0): verify on device
    ]

    /// The app names the Settings disclosure claims support for, in table order and deduped (several
    /// bundle-ID families map to one app). The caption is the feature's honesty, so it is DERIVED from
    /// `families` rather than hand-copied beside it: add, rename or drop a row and the copy follows, and
    /// `MeetingAppsTests` fails if this list and the table ever disagree.
    public static var supportedDisplayNames: [String] {
        var seen: Set<String> = []
        return families.compactMap { seen.insert($0.app.displayName).inserted ? $0.app.displayName : nil }
    }

    public static func classify(bundleID: String) -> MeetingApp? {
        guard !bundleID.isEmpty, !bundleID.hasPrefix(ownPrefix) else { return nil }
        return families.first { bundleID == $0.prefix || bundleID.hasPrefix($0.prefix + ".") }?.app
    }
}
