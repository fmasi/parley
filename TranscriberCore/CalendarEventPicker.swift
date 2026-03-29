import EventKit

public enum CalendarEventPicker {
    /// Picks the best current event from a list.
    /// Filters out all-day events and declined events.
    /// Tiebreaker: most recently started.
    public static func bestCurrentEvent(from events: [EKEvent]) -> EKEvent? {
        events
            .filter { !$0.isAllDay }
            .max { $0.startDate < $1.startDate }
    }
}
