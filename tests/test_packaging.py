"""Validation tests for packaging artifacts."""
import os
import plistlib
import stat
import subprocess
from pathlib import Path

import pytest

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


def test_embed_script_excludes_torch_headers():
    content = (PACKAGING_DIR / "embed_python.sh").read_text()
    assert "torch/include" in content


def test_embed_script_excludes_test_directories():
    content = (PACKAGING_DIR / "embed_python.sh").read_text()
    assert "--exclude='tests/'" in content
    assert "--exclude='test/'" in content


# --- Embedded bundle smoke test (skipped if bundle not built yet) ---

BUNDLE_PYTHON = (
    Path(__file__).parent.parent
    / "dist/AudioTranscribe.app/Contents/Resources/python/bin/python3"
)


def _bundle_env():
    """Build an environment mirroring what TranscriptionRunner sets for the embedded Python."""
    python_root = BUNDLE_PYTHON.parent.parent
    site_packages = python_root / "lib" / "python3.11" / "site-packages"
    env = os.environ.copy()
    env["PYTHONHOME"] = str(python_root)
    env["PYTHONPATH"] = str(site_packages)
    env["PATH"] = str(BUNDLE_PYTHON.parent) + os.pathsep + env.get("PATH", "")
    return env


@pytest.mark.skipif(not BUNDLE_PYTHON.exists(), reason="bundle not built — run package_app.sh first")
def test_bundle_python_imports_ml_stack():
    """Verify the embedded Python can import all runtime ML dependencies.

    This test catches broken bundle exclusions — it runs against the actual
    embedded interpreter, not the host conda env.
    """
    script = (
        "import mlx_whisper, pyannote.audio, torch, torchaudio, "
        "numpy, scipy, pandas, numba, matplotlib, PIL, sklearn, "
        "huggingface_hub, safetensors; print('OK')"
    )
    result = subprocess.run(
        [str(BUNDLE_PYTHON), "-c", script],
        capture_output=True, text=True, timeout=60,
        env=_bundle_env(),
    )
    assert result.returncode == 0, (
        f"Bundle import failed:\nstdout: {result.stdout}\nstderr: {result.stderr}"
    )
    assert result.stdout.strip() == "OK"


@pytest.mark.skipif(not BUNDLE_PYTHON.exists(), reason="bundle not built — run package_app.sh first")
def test_bundle_excludes_torch_headers():
    """torch/include should not be present in the embedded bundle."""
    torch_include = BUNDLE_PYTHON.parent.parent / "lib/python3.11/site-packages/torch/include"
    assert not torch_include.exists(), "torch/include was embedded — update embed_python.sh excludes"


@pytest.mark.skipif(not BUNDLE_PYTHON.exists(), reason="bundle not built — run package_app.sh first")
def test_bundle_excludes_pandas_tests():
    """pandas/tests should not be present in the embedded bundle (saves ~38 MB)."""
    pandas_tests = BUNDLE_PYTHON.parent.parent / "lib/python3.11/site-packages/pandas/tests"
    assert not pandas_tests.exists(), "pandas/tests was embedded — update embed_python.sh excludes"


def _load_plist(name):
    with open(PACKAGING_DIR / name, "rb") as f:
        return plistlib.load(f)
