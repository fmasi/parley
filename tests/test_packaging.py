"""Validation tests for packaging artifacts."""
import os
import plistlib
import stat
from pathlib import Path

PACKAGING_DIR = Path(__file__).parent.parent / "packaging"


def test_info_plist_exists():
    assert (PACKAGING_DIR / "Info.plist").exists()


def test_info_plist_has_bundle_id():
    plist = _load_plist("Info.plist")
    assert plist["CFBundleIdentifier"] == "com.audio-transcribe.app"


def test_info_plist_has_executable():
    plist = _load_plist("Info.plist")
    assert plist["CFBundleExecutable"] == "AudioTranscribe"


def test_info_plist_is_menu_bar_app():
    plist = _load_plist("Info.plist")
    assert plist["LSUIElement"] is True


def test_info_plist_requires_macos_15():
    plist = _load_plist("Info.plist")
    assert plist["LSMinimumSystemVersion"] == "15.0"


def test_info_plist_has_screen_capture_description():
    plist = _load_plist("Info.plist")
    assert "NSScreenCaptureUsageDescription" in plist
    assert len(plist["NSScreenCaptureUsageDescription"]) > 10


def test_info_plist_has_microphone_description():
    plist = _load_plist("Info.plist")
    assert "NSMicrophoneUsageDescription" in plist
    assert len(plist["NSMicrophoneUsageDescription"]) > 10


# --- XPC service Info.plist ---

def test_xpc_plist_exists():
    assert (PACKAGING_DIR / "AudioCaptureHelper-Info.plist").exists()


def test_xpc_plist_has_bundle_id():
    plist = _load_plist("AudioCaptureHelper-Info.plist")
    assert plist["CFBundleIdentifier"] == "com.audio-transcribe.capture-helper"


def test_xpc_plist_has_xpc_package_type():
    plist = _load_plist("AudioCaptureHelper-Info.plist")
    assert plist["CFBundlePackageType"] == "XPC!"


def test_xpc_plist_has_service_type():
    plist = _load_plist("AudioCaptureHelper-Info.plist")
    assert plist["XPCService"]["ServiceType"] == "Application"


# --- embed_python.sh ---

def test_embed_script_exists():
    assert (PACKAGING_DIR / "embed_python.sh").exists()


def test_embed_script_is_executable():
    st = (PACKAGING_DIR / "embed_python.sh").stat()
    assert st.st_mode & stat.S_IXUSR


def test_embed_script_uses_set_euo_pipefail():
    content = (PACKAGING_DIR / "embed_python.sh").read_text()
    assert "set -euo pipefail" in content


def test_embed_script_checks_conda_prefix():
    content = (PACKAGING_DIR / "embed_python.sh").read_text()
    assert "CONDA_PREFIX" in content


def test_embed_script_copies_python_scripts():
    content = (PACKAGING_DIR / "embed_python.sh").read_text()
    assert "transcribe.py" in content
    assert "config_manager.py" in content


def _load_plist(name):
    with open(PACKAGING_DIR / name, "rb") as f:
        return plistlib.load(f)
