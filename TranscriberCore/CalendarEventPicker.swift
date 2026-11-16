import EventKit

public enum CalendarEventPicker {
    /// How far back the lookup's EventKit window reaches (`CalendarService`): an event that started earlier in the day is
    /// still found in progress.
    public static let lookbackHours = 12

    /// What a lookup found, and why (#358): the event (if any), the rule that chose it, and a summary for the unified log.
    /// The summary holds counts and durations only — never a title — so it can be logged `.public`; the title is `.private`.
    public struct Pick {
        public enum Reason: String, Equatable, Sendable {
            /// No full calendar access: EventKit answers with no events at all, indistinguishable from an empty calendar.
            case noAccess
            /// Nothing in the window: no event, or a calendar Parley cannot see (not in macOS Calendar).
            case noEvents
            /// Events in the window, none current: all-day, declined, already ended (a call that overran its slot), or
            /// starting after the lookahead.
            case nothingCurrent
            /// The window contains now.
            case inProgress
            /// Starts within the lookahead.
            case upcoming
        }

        public let event: EKEvent?
        public let reason: Reason
        /// How many events the rule chose among: in progress (`.inProgress`) or starting within the lookahead (`.upcoming`).
        public let candidates: Int
        public let summary: String
    }

    /// Picks the best calendar event to label a recording about to start.
    ///
    /// Decision rule (in order):
    /// 1. Skip all-day events.
    /// 2. If any event is in progress (`startDate <= now < endDate`), pick the most recently
    ///    started one — that's the meeting the user is currently in.
    /// 3. Otherwise, if any event starts within the next `lookaheadMinutes`, pick the
    ///    earliest one — the user is starting recording slightly before a scheduled meeting.
    /// 4. Otherwise return `nil`.
    ///
    /// In-progress always wins over upcoming, even when the upcoming meeting starts sooner.
    /// Just-ended meetings (where `endDate <= now`) are intentionally excluded — the user has
    /// presumably moved on. The grace window is a soft "starting early" allowance, not a way
    /// to attach old meetings to new recordings.
    public static func pickEvent(
        from events: [EKEvent],
        now: Date,
        lookaheadMinutes: Int
    ) -> EKEvent? {
        pick(from: events, declinedCount: 0, now: now, lookaheadMinutes: lookaheadMinutes).event
    }

    /// `pickEvent`, with why (#358). `events` are the window's events the user has not declined; `declinedCount` is how
    /// many were left out for that (EventKit's attendees cannot be built in a test, so the filter stays with the caller).
    public static func pick(from events: [EKEvent], declinedCount: Int, now: Date, lookaheadMinutes: Int) -> Pick {
        let timed = events.filter { !$0.isAllDay }

        let inProgress = timed.filter { $0.startDate <= now && $0.endDate > now }
        if let mostRecent = inProgress.max(by: { $0.startDate < $1.startDate }) {
            return Pick(event: mostRecent, reason: .inProgress, candidates: inProgress.count,
                        summary: "chose 1 of \(counted(inProgress.count)) in progress (the one that started last)")
        }

        let lookahead = max(lookaheadMinutes, 0)
        let graceEnd = now.addingTimeInterval(TimeInterval(lookahead) * 60)
        let upcoming = lookahead > 0 ? timed.filter { $0.startDate > now && $0.startDate <= graceEnd } : []
        if let earliest = upcoming.min(by: { $0.startDate < $1.startDate }) {
            return Pick(event: earliest, reason: .upcoming, candidates: upcoming.count,
                        summary: "chose 1 of \(counted(upcoming.count)) starting within \(lookahead) min (the earliest)")
        }

        let seen = events.count + declinedCount
        guard seen > 0 else {
            return Pick(event: nil, reason: .noEvents, candidates: 0,
                        summary: "no event in the window (\(lookbackHours) h back, \(lookahead) min ahead)")
        }
        let allDay = events.count - timed.count
        let ended = timed.filter { $0.endDate <= now }
        let later = timed.filter { $0.startDate > graceEnd }.count
        var endedText = "\(ended.count) ended"
        if let latest = ended.map(\.endDate).max() {
            endedText += " (the latest \(Int(now.timeIntervalSince(latest) / 60)) min ago)"
        }
        return Pick(event: nil, reason: .nothingCurrent, candidates: 0,
                    summary: "none current: \(counted(seen)) in the window — \(allDay) all-day, \(declinedCount) declined, "
                        + "\(endedText), \(later) later than \(lookahead) min")
    }

    /// Whether EventKit will hand this app any events: only with full access. Write-only access (macOS 14+) reads nothing.
    public static func canRead(_ status: EKAuthorizationStatus) -> Bool { status == .fullAccess }

    /// The pick of a lookup that could not read the calendar.
    public static func noAccess(_ status: EKAuthorizationStatus) -> Pick {
        let why: String
        switch status {
        case .notDetermined: why = "never asked"
        case .writeOnly: why = "add events only"
        case .restricted: why = "restricted"
        case .denied: why = "denied"
        default: why = "status \(status.rawValue)"
        }
        return Pick(event: nil, reason: .noAccess, candidates: 0, summary: "no calendar access (\(why))")
    }

    private static func counted(_ n: Int) -> String { n == 1 ? "1 event" : "\(n) events" }
}
