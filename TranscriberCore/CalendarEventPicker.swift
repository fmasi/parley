import EventKit

public enum CalendarEventPicker {
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
        let timed = events.filter { !$0.isAllDay }

        let inProgress = timed.filter { $0.startDate <= now && $0.endDate > now }
        if let mostRecent = inProgress.max(by: { $0.startDate < $1.startDate }) {
            return mostRecent
        }

        guard lookaheadMinutes > 0 else { return nil }
        let graceEnd = now.addingTimeInterval(TimeInterval(lookaheadMinutes) * 60)
        let upcoming = timed.filter { $0.startDate > now && $0.startDate <= graceEnd }
        return upcoming.min(by: { $0.startDate < $1.startDate })
    }
}
