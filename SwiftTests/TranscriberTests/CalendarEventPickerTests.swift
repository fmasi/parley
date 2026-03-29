import Testing
import EventKit
@testable import TranscriberCore

struct CalendarEventPickerTests {
    private let store = EKEventStore()

    private func makeEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false
    ) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = isAllDay
        return event
    }

    // MARK: - Empty input

    @Test func emptyArrayReturnsNil() {
        let result = CalendarEventPicker.bestCurrentEvent(from: [])
        #expect(result == nil)
    }

    // MARK: - All-day filter

    @Test func filtersOutAllDayEvents() {
        let allDay = makeEvent(
            title: "Holiday",
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: true
        )
        let result = CalendarEventPicker.bestCurrentEvent(from: [allDay])
        #expect(result == nil)
    }

    @Test func keepsNonAllDayEvents() {
        let meeting = makeEvent(
            title: "Standup",
            startDate: Date().addingTimeInterval(-1800),
            endDate: Date().addingTimeInterval(1800)
        )
        let result = CalendarEventPicker.bestCurrentEvent(from: [meeting])
        #expect(result?.title == "Standup")
    }

    // MARK: - Tiebreaker: most recently started

    @Test func picksMostRecentlyStartedEvent() {
        let earlier = makeEvent(
            title: "Earlier Meeting",
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(1800)
        )
        let later = makeEvent(
            title: "Later Meeting",
            startDate: Date().addingTimeInterval(-600),
            endDate: Date().addingTimeInterval(3000)
        )
        let result = CalendarEventPicker.bestCurrentEvent(from: [earlier, later])
        #expect(result?.title == "Later Meeting")
    }

    // MARK: - Mixed: all-day + timed

    @Test func filtersAllDayAndPicksTimed() {
        let allDay = makeEvent(
            title: "Birthday",
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: true
        )
        let timed = makeEvent(
            title: "Sprint Review",
            startDate: Date().addingTimeInterval(-900),
            endDate: Date().addingTimeInterval(2700)
        )
        let result = CalendarEventPicker.bestCurrentEvent(from: [allDay, timed])
        #expect(result?.title == "Sprint Review")
    }

    // MARK: - All filtered out

    @Test func allEventsFilteredReturnsNil() {
        let allDay1 = makeEvent(
            title: "Holiday",
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: true
        )
        let allDay2 = makeEvent(
            title: "Birthday",
            startDate: Date().addingTimeInterval(-7200),
            endDate: Date().addingTimeInterval(7200),
            isAllDay: true
        )
        let result = CalendarEventPicker.bestCurrentEvent(from: [allDay1, allDay2])
        #expect(result == nil)
    }
}
