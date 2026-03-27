import json
import pytest
from pathlib import Path
from unittest.mock import patch


def test_config_defaults(tmp_path):
    from service.config_manager import ConfigManager, Config
    cm = ConfigManager(config_path=tmp_path / "config.json")
    assert cm.config.silence_timeout_minutes == 5
    assert cm.config.silence_detection_enabled is True
    assert cm.config.output_format == "txt"
    assert cm.config.launch_on_startup is True
    assert cm.config.log_level == "info"
    assert "Recordings" in cm.config.recording_directory


def test_config_saves_and_reloads(tmp_path):
    from service.config_manager import ConfigManager
    path = tmp_path / "config.json"
    cm = ConfigManager(config_path=path)
    cm.update(silence_timeout_minutes=10, output_format="srt")
    assert path.exists()
    cm2 = ConfigManager(config_path=path)
    assert cm2.config.silence_timeout_minutes == 10
    assert cm2.config.output_format == "srt"


def test_config_update_ignores_unknown_keys(tmp_path):
    from service.config_manager import ConfigManager
    cm = ConfigManager(config_path=tmp_path / "config.json")
    cm.update(nonexistent_key="value")  # should not raise
    assert not hasattr(cm.config, "nonexistent_key")


def test_config_creates_parent_dirs(tmp_path):
    from service.config_manager import ConfigManager
    nested = tmp_path / "a" / "b" / "config.json"
    cm = ConfigManager(config_path=nested)
    cm.save()
    assert nested.exists()
