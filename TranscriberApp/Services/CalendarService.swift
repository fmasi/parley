import EventKit
import TranscriberCore

@MainActor
final class CalendarService {
    private let store = EKEventStore()

    func requestAccess() {
        Task {
            try? await store.requestFullAccessToEvents()
        }
    }

    func currentEventTitle(from calendars: [EKCalendar]? = nil) -> String? {
        let now = Date()
        // Search a window around now to catch events that started recently
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-12 * 3600),
            end: now.addingTimeInterval(1 * 3600),
            calendars: calendars
        )
        let events = store.events(matching: predicate)

        // Filter to events happening right now
        let current = events.filter { $0.startDate <= now && $0.endDate > now }

        // Filter out declined events
        let notDeclined = current.filter { event in
            guard let attendees = event.attendees else { return true }
            let selfAttendee = attendees.first { $0.isCurrentUser }
            guard let me = selfAttendee else { return true }
            return me.participantStatus != .declined
        }

        return CalendarEventPicker.bestCurrentEvent(from: notDeclined)?.title
    }
}
