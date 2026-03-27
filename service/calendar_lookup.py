"""Apple Calendar lookup via EventKit (PyObjC).

Gracefully degrades when EventKit is unavailable (non-macOS or permission denied).
"""
import re
from typing import Optional

try:
    import EventKit
    from EventKit import EKEventStore
    from Foundation import NSDate, NSCalendar, NSCalendarUnitYear, NSCalendarUnitMonth, NSCalendarUnitDay
    EVENTKIT_AVAILABLE = True
except ImportError:
    EVENTKIT_AVAILABLE = False
    EKEventStore = None


class CalendarLookup:
    """Returns the title of the currently active Apple Calendar event, if any."""

    def __init__(self):
        self._store = None
        if EVENTKIT_AVAILABLE:
            try:
                self._store = EKEventStore.alloc().init()
            except Exception:
                self._store = None

    def get_current_event_title(self) -> Optional[str]:
        """Returns sanitized title of current calendar event, or None."""
        if not EVENTKIT_AVAILABLE or self._store is None:
            return None
        try:
            now = NSDate.date()
            predicate = self._store.predicateForEventsWithStartDate_endDate_calendars_(
                now, now, None
            )
            events = self._store.eventsMatchingPredicate_(predicate)
            if events and len(events) > 0:
                title = str(events[0].title())
                return self._sanitize(title)
        except Exception:
            return None
        return None

    def _sanitize(self, title: str) -> str:
        """Convert event title to a filesystem-safe recording name."""
        title = title.strip()
        title = re.sub(r"[^\w\s-]", "", title)
        title = re.sub(r"[\s]+", "_", title)
        return title
