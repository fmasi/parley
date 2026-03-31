import json
from dataclasses import dataclass, asdict, fields
from pathlib import Path

CONFIG_DIR = Path.home() / ".audio-transcribe"
CONFIG_FILE = CONFIG_DIR / "config.json"


@dataclass
class Config:
    recording_directory: str = str(Path.home() / "Documents" / "Recordings")
    silence_timeout_minutes: int = 5
    silence_detection_enabled: bool = True
    output_format: str = "txt"
    launch_on_startup: bool = True
    suppress_capture_warning: bool = False
    hf_token: str = ""


class ConfigManager:
    """Read/write user settings from ~/.audio-transcribe/config.json.

    Parallelization note: this is a shared config object; no changes needed
    for parallel workers since config is read-only during recording sessions.
    """

    def __init__(self, config_path: Path = CONFIG_FILE):
        self._path = config_path
        self._config = self._load()

    def _load(self) -> Config:
        if self._path.exists():
            try:
                with open(self._path, encoding="utf-8") as f:
                    data = json.load(f)
                valid = {f.name for f in fields(Config)}
                return Config(**{k: v for k, v in data.items() if k in valid})
            except json.JSONDecodeError:
                pass  # Corrupted config — fall back to defaults
        return Config()

    def save(self):
        self._path.parent.mkdir(parents=True, exist_ok=True)
        with open(self._path, "w", encoding="utf-8") as f:
            json.dump(asdict(self._config), f, indent=2)

    @property
    def config(self) -> Config:
        return self._config

    def update(self, **kwargs):
        valid = {f.name for f in fields(Config)}
        for k, v in kwargs.items():
            if k in valid:
                setattr(self._config, k, v)
        self.save()
