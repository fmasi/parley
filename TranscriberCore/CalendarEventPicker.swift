import EventKit

public enum CalendarEventPicker {
    /// Picks the best current event from a list.
    /// Filters out all-day events and declined events.
    /// Tiebreaker: most recently started.
    public static func bestCurrentEvent(from events: [EKEvent]) -> EKEvent? {
        nil // TDD — will implement after tests
    }
}
