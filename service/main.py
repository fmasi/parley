# service/main.py
"""Entry point for the transcription service daemon.

Run directly:  python service/main.py
Via launchd:   configured in com.audio-transcribe.plist
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from service.config_manager import ConfigManager
from service.logger import get_logger
from service.menu_bar_app import TranscriptionApp

log = get_logger("main")


def main():
    log.info("Transcription service starting")
    config_manager = ConfigManager()
    recordings_dir = Path(config_manager.config.recording_directory).expanduser()
    recordings_dir.mkdir(parents=True, exist_ok=True)
    app = TranscriptionApp(config_manager=config_manager)
    log.info("Menu bar app initialized — running")
    app.run()


if __name__ == "__main__":
    main()
