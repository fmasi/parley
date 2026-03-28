"""Validation tests for packaging artifacts."""
import os
import plistlib
import stat
from pathlib import Path

PACKAGING_DIR = Path(__file__).parent.parent / "packaging"


def test_info_plist_exists():
    assert (PACKAGING_DIR / "Info.plist").exists()


def test_info_plist_has_bundle_id():
    plist = _load_plist()
    assert plist["CFBundleIdentifier"] == "com.audio-transcribe.app"


def test_info_plist_has_executable():
    plist = _load_plist()
    assert plist["CFBundleExecutable"] == "AudioTranscribe"


def test_info_plist_is_menu_bar_app():
    plist = _load_plist()
    assert plist["LSUIElement"] is True


def test_info_plist_requires_macos_15():
    plist = _load_plist()
    assert plist["LSMinimumSystemVersion"] == "15.0"


def test_info_plist_has_screen_capture_description():
    plist = _load_plist()
    assert "NSScreenCaptureUsageDescription" in plist
    assert len(plist["NSScreenCaptureUsageDescription"]) > 10


def test_info_plist_has_microphone_description():
    plist = _load_plist()
    assert "NSMicrophoneUsageDescription" in plist
    assert len(plist["NSMicrophoneUsageDescription"]) > 10


def test_launcher_exists():
    assert (PACKAGING_DIR / "launcher.sh").exists()


def test_launcher_has_bash_shebang():
    content = (PACKAGING_DIR / "launcher.sh").read_text()
    assert content.startswith("#!/bin/bash")


def test_launcher_sets_pythonhome():
    content = (PACKAGING_DIR / "launcher.sh").read_text()
    assert "PYTHONHOME" in content


def test_launcher_sets_pythonpath():
    content = (PACKAGING_DIR / "launcher.sh").read_text()
    assert "PYTHONPATH" in content


def test_launcher_uses_exec():
    """exec replaces the shell so Python IS the app process for TCC."""
    content = (PACKAGING_DIR / "launcher.sh").read_text()
    assert "\nexec " in content


def test_launcher_is_executable():
    st = (PACKAGING_DIR / "launcher.sh").stat()
    assert st.st_mode & stat.S_IXUSR


def test_build_script_exists():
    assert (PACKAGING_DIR / "build_app.sh").exists()


def test_build_script_is_executable():
    path = PACKAGING_DIR / "build_app.sh"
    assert os.access(path, os.X_OK)


def test_build_script_uses_set_euo_pipefail():
    content = (PACKAGING_DIR / "build_app.sh").read_text()
    assert "set -euo pipefail" in content


def test_build_script_creates_app_structure():
    """Checks the script creates the expected directory layout."""
    content = (PACKAGING_DIR / "build_app.sh").read_text()
    assert "Contents/MacOS" in content
    assert "Contents/Resources" in content


def test_build_script_copies_source_and_binary():
    content = (PACKAGING_DIR / "build_app.sh").read_text()
    assert "audio-capture-helper" in content
    assert "service/" in content
    assert "transcribe.py" in content


def test_build_script_signs_bundle():
    content = (PACKAGING_DIR / "build_app.sh").read_text()
    assert "codesign" in content


def test_build_script_validates_python_environment():
    content = (PACKAGING_DIR / "build_app.sh").read_text()
    assert "import rumps" in content
    assert "import soundfile" in content


def _load_plist():
    with open(PACKAGING_DIR / "Info.plist", "rb") as f:
        return plistlib.load(f)
