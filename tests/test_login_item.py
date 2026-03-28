"""Tests for login item registration via SMAppService."""
from unittest.mock import patch, MagicMock
import service.login_item as li


def test_is_app_bundle_false_in_terminal():
    """Running from pytest/terminal is not an app bundle."""
    assert li.is_app_bundle() is False


def test_is_app_bundle_true_when_path_contains_app_contents():
    """Detects .app bundle from executable path."""
    fake_path = "/Applications/AudioTranscribe.app/Contents/Resources/python/bin/python3"
    with patch("service.login_item.os.path.realpath", return_value=fake_path):
        assert li.is_app_bundle() is True


def test_set_login_item_returns_false_outside_bundle():
    """Silently no-ops when not in an app bundle."""
    with patch.object(li, "is_app_bundle", return_value=False):
        assert li.set_login_item(True) is False


def test_set_login_item_calls_register():
    """Calls SMAppService.mainApp().register when in a bundle."""
    mock_service = MagicMock()
    mock_service.registerAndReturnError_.return_value = (True, None)
    mock_sma = MagicMock()
    mock_sma.mainApp.return_value = mock_service

    with patch.object(li, "is_app_bundle", return_value=True), \
         patch.object(li, "_SM_AVAILABLE", True), \
         patch.object(li, "SMAppService", mock_sma, create=True):
        assert li.set_login_item(True) is True
        mock_service.registerAndReturnError_.assert_called_once_with(None)


def test_set_login_item_calls_unregister():
    """Calls SMAppService.mainApp().unregister when disabling."""
    mock_service = MagicMock()
    mock_service.unregisterAndReturnError_.return_value = (True, None)
    mock_sma = MagicMock()
    mock_sma.mainApp.return_value = mock_service

    with patch.object(li, "is_app_bundle", return_value=True), \
         patch.object(li, "_SM_AVAILABLE", True), \
         patch.object(li, "SMAppService", mock_sma, create=True):
        assert li.set_login_item(False) is True
        mock_service.unregisterAndReturnError_.assert_called_once_with(None)


def test_set_login_item_returns_false_when_sm_unavailable():
    """Gracefully returns False when ServiceManagement not installed."""
    with patch.object(li, "is_app_bundle", return_value=True), \
         patch.object(li, "_SM_AVAILABLE", False):
        assert li.set_login_item(True) is False
