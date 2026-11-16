import Foundation

/// What the meeting island shows, and every transition between its contents (#358). Pure: `MeetingPromptPresenter` (app
/// target, unreachable from tests) builds the offers and carries out the effects; which content may replace or bring back
/// which is decided — and tested — here.
///
/// Three contents share the one island: the start offer, the stop offer, and — after a one-click start — the recording
/// itself (its name, Rename…, Hide). A withdrawal takes down only its own content: the recording island that replaced a
/// start offer survives that offer's withdrawal, and comes back, compact, when a stop offer it gave way to is withdrawn.
public enum MeetingIslandContent: Equatable, Sendable {
    case startOffer, stopOffer, recording
}

/// The recording a one-click start began.
public struct RecordingIslandState: Equatable, Sendable {
    public let sessionKey: String
    /// Its name came from the calendar — at the start, or a title that arrived after it.
    public var fromCalendar: Bool
    /// The user chose Hide, or turned meeting sensing off: not shown again for this recording.
    public var hidden: Bool

    public init(sessionKey: String, fromCalendar: Bool, hidden: Bool = false) {
        self.sessionKey = sessionKey
        self.fromCalendar = fromCalendar
        self.hidden = hidden
    }
}

public struct MeetingIslandState: Equatable, Sendable {
    /// On screen now; nil = no island.
    public var showing: MeetingIslandContent?
    public var recording: RecordingIslandState?

    public init(showing: MeetingIslandContent? = nil, recording: RecordingIslandState? = nil) {
        self.showing = showing
        self.recording = recording
    }
}

public enum MeetingIslandEvent: Equatable, Sendable {
    /// The presenter put a start (or stop) offer on the island.
    case startOfferShown, stopOfferShown
    /// The engine withdrew it.
    case startOfferWithdrawn, stopOfferWithdrawn
    /// The user answered the offer on screen (Record, Name it first…, Stop): it goes.
    case offerAnswered
    /// A one-click start is up.
    case recordingStarted(sessionKey: String, fromCalendar: Bool)
    /// A late calendar title named recording `sessionKey`.
    case calendarTitleAdopted(sessionKey: String)
    /// The user typed a name for the recording.
    case renamedByUser
    /// Hide, from the recording island's menu.
    case hideChosen
    /// The phase left `.recording`.
    case recordingEnded
    /// `meeting_sensing` went off: no island at all.
    case sensingTurnedOff
}

public enum MeetingIslandEffect: Equatable, Sendable {
    case hide
    /// Show the recording island (expanded, or compact).
    case showRecording(expanded: Bool)
    /// Show it again with its current name, expanded or compact as the user left it.
    case refreshRecording
}

public enum MeetingIslandReducer {
    /// `recordingSessionKey`: the recording in progress (`RecordingCoordinator.recordingSessionKey`), nil when none.
    /// `sensingOn`: `meeting_sensing` is `prompt`.
    public static func reduce(_ state: MeetingIslandState, _ event: MeetingIslandEvent, recordingSessionKey: String?,
                              sensingOn: Bool) -> (state: MeetingIslandState, effects: [MeetingIslandEffect]) {
        var s = state
        var effects: [MeetingIslandEffect] = []

        /// The recording island may be on screen: its recording is the one recording, the user has not hidden it, sensing
        /// is on, and no stop offer holds the island.
        func recordingMayShow() -> Bool {
            guard let recording = s.recording, !recording.hidden, sensingOn,
                  recording.sessionKey == recordingSessionKey else { return false }
            return s.showing != .stopOffer
        }
        func hide() {
            if s.showing != nil { effects.append(.hide) }
            s.showing = nil
        }
        func showRecording(expanded: Bool) {
            guard recordingMayShow() else { return }
            effects.append(.showRecording(expanded: expanded))
            s.showing = .recording
        }
        func refresh() {
            if s.showing == .recording, recordingMayShow() { effects.append(.refreshRecording) }
        }

        switch event {
        case .startOfferShown:
            s.showing = .startOffer
        case .stopOfferShown:
            s.showing = .stopOffer
        case .startOfferWithdrawn:
            if s.showing == .startOffer { hide() }
        case .stopOfferWithdrawn:
            // The call came back, or "Keep recording": the recording island returns, compact.
            if s.showing == .stopOffer {
                hide()
                showRecording(expanded: false)
            }
        case .offerAnswered:
            hide()
        case .recordingStarted(let key, let fromCalendar):
            s.recording = RecordingIslandState(sessionKey: key, fromCalendar: fromCalendar)
            showRecording(expanded: true)
        case .calendarTitleAdopted(let key):
            guard s.recording?.sessionKey == key else { break }
            s.recording?.fromCalendar = true
            refresh()
        case .renamedByUser:
            guard s.recording != nil else { break }
            s.recording?.fromCalendar = false
            refresh()
        case .hideChosen, .sensingTurnedOff:
            s.recording?.hidden = true
            if s.showing == .recording { hide() }
        case .recordingEnded:
            s.recording = nil
            // A stop offer still up goes with the engine's own withdrawal.
            if s.showing == .recording { hide() }
        }
        return (s, effects)
    }
}
