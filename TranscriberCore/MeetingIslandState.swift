import Foundation

/// What the meeting island shows, and every transition between its contents (#358). Pure: `MeetingPromptPresenter` (app
/// target, unreachable from tests) builds the offers and carries out the effects; which content may replace or bring back
/// which is decided — and tested — here.
///
/// Three contents share the one island: the start offer, the stop offer, and — after a one-click start — the recording
/// itself (its name, Rename…, Hide). A withdrawal takes down only its own content: the recording island that replaced a
/// start offer survives that offer's withdrawal.
///
/// The recording island is a confirmation, not a fixture (owner decision): it withdraws once its collapse delay
/// (`MeetingIslandCollapse`, about 20 s, longer while the pointer rests on it) runs out, and never comes back for that
/// recording — not for a late calendar title, a rename, or a stop offer's withdrawal. The menu's name row carries the name
/// for the rest of the call.
public enum MeetingIslandContent: Equatable, Sendable {
    case startOffer, stopOffer, recording
}

/// The recording a one-click start began.
public struct RecordingIslandState: Equatable, Sendable {
    public let sessionKey: String
    /// Its name came from the calendar — at the start, or a title that arrived after it.
    public var fromCalendar: Bool
    /// Gone for this recording: its delay ran out, a stop offer replaced it, the user chose Hide, or meeting sensing went
    /// off. Never shown again for it.
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
    /// The recording island's collapse delay ran out (`MeetingIslandCollapse`, the island view's own timer).
    case recordingIslandExpired
    /// The phase left `.recording`.
    case recordingEnded
    /// `meeting_sensing` went off: no island at all.
    case sensingTurnedOff
}

public enum MeetingIslandEffect: Equatable, Sendable {
    case hide
    /// Show the recording island, expanded.
    case showRecording
    /// Its name changed while it is up: update its line in place, never restarting its delay.
    case updateRecordingSubtitle
}

public enum MeetingIslandReducer {
    /// `recordingSessionKey`: the recording in progress (`RecordingCoordinator.recordingSessionKey`), nil when none.
    /// `sensingOn`: `meeting_sensing` is `prompt`.
    public static func reduce(_ state: MeetingIslandState, _ event: MeetingIslandEvent, recordingSessionKey: String?,
                              sensingOn: Bool) -> (state: MeetingIslandState, effects: [MeetingIslandEffect]) {
        var s = state
        var effects: [MeetingIslandEffect] = []

        /// The recording island may be on screen: its recording is the one recording, it has not gone for good, and
        /// sensing is on.
        func recordingMayShow() -> Bool {
            guard let recording = s.recording, !recording.hidden, sensingOn else { return false }
            return recording.sessionKey == recordingSessionKey
        }
        func hide() {
            if s.showing != nil { effects.append(.hide) }
            s.showing = nil
        }
        func refresh() {
            if s.showing == .recording, recordingMayShow() { effects.append(.updateRecordingSubtitle) }
        }
        /// The recording island goes for good, hidden now if it is the one on screen.
        func withdrawRecording() {
            s.recording?.hidden = true
            if s.showing == .recording { hide() }
        }

        switch event {
        case .startOfferShown:
            s.showing = .startOffer
        case .stopOfferShown:
            // It replaces the recording island for good: nothing is restored after it.
            if s.showing == .recording { s.recording?.hidden = true }
            s.showing = .stopOffer
        case .startOfferWithdrawn:
            if s.showing == .startOffer { hide() }
        case .stopOfferWithdrawn:
            if s.showing == .stopOffer { hide() }
        case .offerAnswered:
            hide()
        case .recordingStarted(let key, let fromCalendar):
            s.recording = RecordingIslandState(sessionKey: key, fromCalendar: fromCalendar)
            if recordingMayShow() {
                effects.append(.showRecording)
                s.showing = .recording
            }
        case .calendarTitleAdopted(let key):
            guard s.recording?.sessionKey == key else { break }
            s.recording?.fromCalendar = true
            refresh()
        case .renamedByUser:
            guard s.recording != nil else { break }
            s.recording?.fromCalendar = false
            refresh()
        case .hideChosen, .sensingTurnedOff:
            withdrawRecording()
        case .recordingIslandExpired:
            // A stale expiry (a stop offer already holds the island, or nothing does) changes nothing.
            if s.showing == .recording { withdrawRecording() }
        case .recordingEnded:
            s.recording = nil
            // A stop offer still up goes with the engine's own withdrawal.
            if s.showing == .recording { hide() }
        }
        return (s, effects)
    }
}
