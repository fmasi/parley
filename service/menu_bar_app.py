# service/menu_bar_app.py
"""macOS menu bar application using rumps (AppKit wrapper via PyObjC).

State machine:
  IDLE → start_recording() → PROMPTING → RECORDING → stop_recording() → TRANSCRIBING → IDLE
"""
import threading
from datetime import datetime
from pathlib import Path
from typing import Optional

try:
    import rumps
    _RUMPS_AVAILABLE = True
except ImportError:
    _RUMPS_AVAILABLE = False

    class rumps:  # type: ignore
        """Stub so the module is importable without rumps installed."""
        class App:
            def __init__(self, *a, **kw):
                pass
            def run(self):
                pass
        class MenuItem:
            def __init__(self, *a, **kw):
                pass
            def set_callback(self, cb):
                pass
        @staticmethod
        def quit_application(*a, **kw):
            pass
        @staticmethod
        def alert(*a, **kw):
            return 0
        @staticmethod
        def notification(*a, **kw):
            pass
        class Window:
            def __init__(self, *a, **kw):
                pass
            def run(self):
                class R:
                    clicked = 0
                    text = ""
                return R()

from service.audio_capture import AudioCapture
from service.calendar_lookup import CalendarLookup
from service.config_manager import ConfigManager
from service.logger import get_logger
from service.pipeline import Pipeline
from service.rename_dialog import run_rename_dialog
from service.settings_window import SettingsWindowController
from service.silence_detector import SilenceDetector

log = get_logger("menu_bar_app")

ICON_IDLE = "🎙"
ICON_RECORDING = "🔴"
ICON_PROCESSING = "⏳"


class TranscriptionApp(rumps.App):
    """Persistent menu bar app controlling the entire transcription pipeline."""

    def __init__(self, config_manager: ConfigManager):
        super().__init__(ICON_IDLE, quit_button=None)
        self._cm = config_manager
        self._capture: Optional[AudioCapture] = None
        self._silence_detector: Optional[SilenceDetector] = None
        self._silence_thread: Optional[threading.Thread] = None
        self._calendar = CalendarLookup()
        self._settings_ctrl = SettingsWindowController.alloc().initWithConfigManager_(config_manager)

        self._pipeline = Pipeline(
            config=self._cm.config,
            on_rename_ready=self._on_rename_ready,
            on_error=self._on_pipeline_error,
        )

        self.menu = [
            rumps.MenuItem("Start Recording", callback=self.start_recording),
            None,
            rumps.MenuItem("Settings", callback=self.open_settings),
            rumps.MenuItem("View Logs", callback=self.open_logs),
            None,
            rumps.MenuItem("Quit", callback=rumps.quit_application),
        ]

    def start_recording(self, sender):
        recording_name = self._prompt_recording_name()
        if not recording_name:
            return

        output_path = self._build_output_path(recording_name)
        output_path.parent.mkdir(parents=True, exist_ok=True)

        self._capture = AudioCapture(output_path=output_path)
        self._capture.start()

        self.title = ICON_RECORDING
        self.menu["Start Recording"].title = "Stop Recording"
        self.menu["Start Recording"].set_callback(self.stop_recording)

        if self._cm.config.silence_detection_enabled:
            self._start_silence_monitor()

        log.info(f"Recording started: {output_path}")

    def stop_recording(self, sender):
        self._stop_silence_monitor()

        if self._capture:
            audio_path = self._capture.stop()
            self._capture = None
            self.title = ICON_PROCESSING
            self._pipeline.on_recording_complete(audio_path)
            log.info(f"Recording stopped, transcription queued: {audio_path.name}")

        self.menu["Stop Recording"].title = "Start Recording"
        self.menu["Stop Recording"].set_callback(self.start_recording)

    def _start_silence_monitor(self):
        cfg = self._cm.config
        self._silence_detector = SilenceDetector(timeout_minutes=cfg.silence_timeout_minutes)
        self._silence_detector.reset()
        self._silence_thread = threading.Thread(target=self._silence_loop, daemon=True)
        self._silence_thread.start()

    def _stop_silence_monitor(self):
        self._silence_detector = None

    def _silence_loop(self):
        import time
        while self._silence_detector is not None:
            if self._silence_detector.is_timed_out():
                self._prompt_stop_on_silence()
                break
            time.sleep(10)

    def _prompt_stop_on_silence(self):
        response = rumps.alert(
            title="No Audio Detected",
            message="No speech detected for several minutes. Stop recording?",
            ok="Stop Recording",
            cancel="Continue",
        )
        if response == 1:
            self.stop_recording(None)

    def _on_rename_ready(self, json_path):
        self.title = ICON_IDLE
        log.info(f"Transcription complete, launching rename dialog: {json_path.name}")
        run_rename_dialog(json_path)
        rumps.notification(
            title="Transcription Complete",
            subtitle=json_path.stem,
            message="Speaker names saved.",
        )

    def _on_pipeline_error(self, message):
        self.title = ICON_IDLE
        log.error(f"Pipeline error: {message}")
        rumps.notification(
            title="Transcription Failed",
            subtitle="",
            message=message,
        )

    def open_settings(self, sender):
        self._settings_ctrl.show()

    def open_logs(self, sender):
        log_path = Path.home() / ".audio-transcribe" / "logs" / "transcribe-service.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.touch()
        import subprocess
        subprocess.run(["open", str(log_path)])

    def _prompt_recording_name(self):
        suggested = self._calendar.get_current_event_title() or "Recording"
        response = rumps.Window(
            message="Recording name:",
            title="Start Recording",
            default_text=suggested,
            ok="Start",
            cancel="Cancel",
            dimensions=(300, 24),
        ).run()
        if response.clicked == 1 and response.text.strip():
            return response.text.strip()
        return None

    def _build_output_path(self, name):
        base = Path(self._cm.config.recording_directory).expanduser()
        date_folder = datetime.now().strftime("%Y-%m-%d")
        timestamp = datetime.now().strftime("%H%M%S")
        safe_name = name.replace(" ", "_").replace("/", "_")
        return base / date_folder / f"{timestamp}_{safe_name}.m4a"
