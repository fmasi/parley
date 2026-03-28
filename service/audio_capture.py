"""Captures microphone + system audio using the audio-capture-helper Swift binary.

The helper uses ScreenCaptureKit (macOS 14.0+) with:
  - capturesAudio     = true  → system audio (Zoom, Teams, Meet, speakers…)
  - captureMicrophone = true  → local microphone

Both streams are delivered by a single SCStream into one WAV file.
Python only manages the subprocess lifecycle — no audio processing here.

Requires 'Screen & System Audio Recording' permission in
System Settings → Privacy & Security (macOS prompts on first use).
"""
import signal
import subprocess
from enum import Enum
from pathlib import Path
from typing import Optional

from service.logger import get_logger

log = get_logger("audio_capture")

HELPER_BINARY = Path(__file__).parent.parent / "bin" / "audio-capture-helper"


class CaptureMode(Enum):
    FULL = "full"               # mic + system audio via Swift helper
    UNAVAILABLE = "unavailable" # helper binary not found — cannot record


class AudioCapture:
    """Records microphone + system audio to a WAV file via the Swift helper.

    Interface:
        capture = AudioCapture(output_path)
        mode = capture.start()    # non-blocking; returns CaptureMode
        path = capture.stop()     # blocks until helper exits; returns Path
    """

    def __init__(self, output_path: Path):
        self._output_path = output_path
        self._process: Optional[subprocess.Popen] = None

    def start(self) -> CaptureMode:
        """Begin recording. Non-blocking. Returns CaptureMode."""
        if not HELPER_BINARY.exists():
            log.error(
                f"audio-capture-helper not found at {HELPER_BINARY}. "
                "Run: cd audio_capture_helper && bash build.sh"
            )
            return CaptureMode.UNAVAILABLE

        self._output_path.parent.mkdir(parents=True, exist_ok=True)
        log.info(f"Starting audio capture → {self._output_path.name}")
        self._process = subprocess.Popen(
            [str(HELPER_BINARY), str(self._output_path)],
            stderr=subprocess.PIPE,
            text=True,
        )
        return CaptureMode.FULL

    def stop(self) -> Path:
        """Stop recording. Returns path to WAV file."""
        if self._process is not None:
            log.info("Stopping audio capture (SIGTERM)...")
            self._process.send_signal(signal.SIGTERM)
            try:
                _, stderr = self._process.communicate(timeout=10)
                if stderr:
                    for line in stderr.strip().splitlines():
                        log.info(f"[audio-capture-helper] {line}")
                if self._process.returncode == 2:
                    raise PermissionError(
                        "Screen & System Audio Recording permission denied. "
                        "Grant it in System Settings → Privacy & Security."
                    )
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.communicate()
                log.error("audio-capture-helper did not exit within 10 s — killed")
            finally:
                self._process = None

        if not self._output_path.exists():
            raise RuntimeError(
                f"audio-capture-helper did not produce output: {self._output_path}"
            )

        size_kb = self._output_path.stat().st_size // 1024
        log.info(f"Audio written: {self._output_path.name} ({size_kb} KB)")
        return self._output_path
