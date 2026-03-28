# service/settings_window.py
"""AppKit settings window for configuring the transcription service."""
try:
    import objc
    from AppKit import (
        NSWindow,
        NSTextField,
        NSButton,
        NSPopUpButton,
        NSTitledWindowMask,
        NSClosableWindowMask,
        NSResizableWindowMask,
        NSBackingStoreBuffered,
        NSApp,
        NSSwitchButton,
    )
    from Foundation import NSObject, NSMakeRect
    _APPKIT_AVAILABLE = True
except ImportError:
    _APPKIT_AVAILABLE = False
    NSObject = object

from service.audio_capture import HELPER_BINARY
from service.config_manager import ConfigManager
from service.logger import get_logger

log = get_logger("settings_window")


class SettingsWindowController(NSObject):
    """Shows and manages the settings window."""

    def initWithConfigManager_(self, config_manager: ConfigManager):
        if not _APPKIT_AVAILABLE:
            self._cm = config_manager
            self._window = None
            return self
        self = objc.super(SettingsWindowController, self).init()
        if self is None:
            return None
        self._cm = config_manager
        self._window = None
        return self

    def show(self):
        if not _APPKIT_AVAILABLE:
            log.warning("AppKit not available; cannot show settings window")
            return
        if self._window and self._window.isVisible():
            self._window.makeKeyAndOrderFront_(None)
            return
        self._build_window()
        self._window.makeKeyAndOrderFront_(None)
        NSApp.activateIgnoringOtherApps_(True)

    def _build_window(self):
        cfg = self._cm.config
        rect = NSMakeRect(100, 100, 420, 320)
        style = NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask
        self._window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, style, NSBackingStoreBuffered, False
        )
        self._window.setTitle_("Transcription Service — Settings")

        view = self._window.contentView()
        y = 260

        # Recording directory
        self._add_label(view, "Recording Directory:", (20, y))
        self._dir_field = self._add_text_field(view, cfg.recording_directory, (20, y - 28), width=380)
        y -= 60

        # Output format
        self._add_label(view, "Output Format:", (20, y))
        self._format_popup = NSPopUpButton.alloc().initWithFrame_(NSMakeRect(20, y - 28, 120, 26))
        for fmt in ["txt", "srt", "json"]:
            self._format_popup.addItemWithTitle_(fmt)
        self._format_popup.selectItemWithTitle_(cfg.output_format)
        view.addSubview_(self._format_popup)
        y -= 60

        # Silence detection toggle
        self._add_label(view, "Silence Detection:", (20, y))
        self._silence_toggle = NSButton.alloc().initWithFrame_(NSMakeRect(160, y - 4, 120, 22))
        self._silence_toggle.setButtonType_(NSSwitchButton)
        self._silence_toggle.setTitle_("Enabled")
        self._silence_toggle.setState_(1 if cfg.silence_detection_enabled else 0)
        view.addSubview_(self._silence_toggle)
        y -= 40

        # Silence timeout
        self._add_label(view, "Silence Timeout (minutes):", (20, y))
        self._timeout_field = self._add_text_field(view, str(cfg.silence_timeout_minutes), (260, y - 4), width=60)
        y -= 50

        # Audio capture status (read-only)
        if HELPER_BINARY.exists():
            capture_status = "Full audio capture: Active ✓  (mic + system audio)"
        else:
            capture_status = "Full audio capture: Unavailable — run audio_capture_helper/build.sh ⚠"
        self._add_label(view, capture_status, (20, y))
        y -= 30

        # Save button
        save_btn = NSButton.alloc().initWithFrame_(NSMakeRect(310, 20, 90, 32))
        save_btn.setTitle_("Save")
        save_btn.setTarget_(self)
        save_btn.setAction_(objc.selector(self.save_, signature=b"v@:@"))
        view.addSubview_(save_btn)

    def save_(self, sender):
        try:
            timeout = int(self._timeout_field.stringValue())
        except ValueError:
            timeout = 5

        self._cm.update(
            recording_directory=str(self._dir_field.stringValue()),
            output_format=str(self._format_popup.titleOfSelectedItem()),
            silence_detection_enabled=bool(self._silence_toggle.state()),
            silence_timeout_minutes=timeout,
        )
        log.info("Settings saved")
        self._window.close()

    def _add_label(self, view, text, pos):
        label = NSTextField.alloc().initWithFrame_(NSMakeRect(pos[0], pos[1], 220, 20))
        label.setStringValue_(text)
        label.setEditable_(False)
        label.setBezeled_(False)
        label.setDrawsBackground_(False)
        view.addSubview_(label)

    def _add_text_field(self, view, value, pos, width=200):
        field = NSTextField.alloc().initWithFrame_(NSMakeRect(pos[0], pos[1], width, 24))
        field.setStringValue_(value)
        view.addSubview_(field)
        return field
