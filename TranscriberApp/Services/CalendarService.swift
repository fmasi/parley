import EventKit
import TranscriberCore

@MainActor
final class CalendarService {
    private let store = EKEventStore()

    func currentEventTitle(
        lookaheadMinutes: Int = 10,
        from calendars: [EKCalendar]? = nil
    ) -> String? {
        let now = Date()
        // The predicate window must include both the lookback for in-progress events and
        // the lookahead for imminent ones. EventKit needs at least a few hours back to
        // surface events that started earlier in the day.
        let lookahead = max(lookaheadMinutes, 0)
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-12 * 3600),
            end: now.addingTimeInterval(TimeInterval(lookahead) * 60 + 60),
            calendars: calendars
        )
        let events = store.events(matching: predicate)

        // Filter out declined events before handing to the picker.
        let notDeclined = events.filter { event in
            guard let attendees = event.attendees else { return true }
            let selfAttendee = attendees.first { $0.isCurrentUser }
            guard let me = selfAttendee else { return true }
            return me.participantStatus != .declined
        }

        return CalendarEventPicker.pickEvent(
            from: notDeclined,
            now: now,
            lookaheadMinutes: lookahead
        )?.title
    }
}
