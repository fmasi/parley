import EventKit
import TranscriberCore

/// Deliberately NOT main-actor: `events(matching:)` is a synchronous EventKit query over a
/// 12-hour, all-calendars predicate, and can take seconds with Exchange/Google accounts (#197).
/// `currentEventTitle` runs the whole lookup in a detached task so a caller on the main actor —
/// e.g. the naming panel opening on Start Recording — is never blocked on it.
final class CalendarService {
    func currentEventTitle(
        lookaheadMinutes: Int = 10,
        from calendars: [EKCalendar]? = nil
    ) async -> String? {
        await Task.detached(priority: .userInitiated) {
            // A fresh store per lookup: cheap to create, and avoids sharing an EKEventStore
            // across actor/thread boundaries.
            let store = EKEventStore()
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
        }.value
    }
}
