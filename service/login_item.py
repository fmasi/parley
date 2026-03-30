"""Login item registration via SMAppService (macOS 13+).

When running inside a .app bundle, this module can register the app as a
login item so it starts automatically when the user logs in. Outside a
bundle (e.g., running from Terminal during development), all operations
are silent no-ops.
"""
import os
import sys

from service.logger import get_logger

log = get_logger("login_item")

try:
    from ServiceManagement import SMAppService
    _SM_AVAILABLE = True
except ImportError:
    _SM_AVAILABLE = False


def is_app_bundle() -> bool:
    """Check if running inside a macOS .app bundle."""
    return ".app/Contents/" in os.path.realpath(sys.executable)


def set_login_item(enabled: bool) -> bool:
    """Register or unregister as a login item. Returns True on success."""
    if not is_app_bundle():
        log.debug("Not in .app bundle — login item registration skipped")
        return False

    if not _SM_AVAILABLE:
        log.warning("ServiceManagement framework not available")
        return False

    service = SMAppService.mainApp()
    if enabled:
        success, error = service.registerAndReturnError_(None)
    else:
        success, error = service.unregisterAndReturnError_(None)

    if not success:
        action = "register" if enabled else "unregister"
        log.error(f"Login item {action} failed: {error}")

    return bool(success)
