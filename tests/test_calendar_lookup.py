from unittest.mock import MagicMock, patch


def test_returns_none_when_no_events():
    from service.calendar_lookup import CalendarLookup
    with patch("service.calendar_lookup.EVENTKIT_AVAILABLE", False):
        cl = CalendarLookup()
        assert cl.get_current_event_title() is None


def test_returns_none_on_eventkit_error():
    from service.calendar_lookup import CalendarLookup
    with patch("service.calendar_lookup.EVENTKIT_AVAILABLE", True):
        with patch("service.calendar_lookup.EKEventStore") as mock_store:
            mock_store.alloc.return_value.init.return_value.requestAccessToEntityType_completion_ = MagicMock()
            cl = CalendarLookup()
            cl._store = None
            assert cl.get_current_event_title() is None


def test_sanitizes_event_title():
    from service.calendar_lookup import CalendarLookup
    cl = CalendarLookup.__new__(CalendarLookup)
    assert cl._sanitize("Client: Meeting / Q1") == "Client_Meeting_Q1"
    assert cl._sanitize("  spaces  ") == "spaces"
    assert cl._sanitize("already_good") == "already_good"
