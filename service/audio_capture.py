"""Captures microphone + system audio using the audio-capture-helper Swift binary.

The helper uses ScreenCaptureKit (macOS 15.0+) to capture two separate streams:
  - System audio (Zoom, Teams, Meet, speakers…) → <base>.wav
  - Local microphone → <base>_mic.wav

Each file is written at its native sample rate. The downstream transcription
pipeline processes them separately for better speaker attribution.

Requires 'Screen & System Audio Recording' permission in
System Settings → Privacy & Security (macOS prompts on first use).
"""
import signal
import subprocess
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Optional

from service.logger import get_logger

log = get_logger("audio_capture")

HELPER_BINARY = Path(__file__).parent.parent / "bin" / "audio-capture-helper"


class CaptureMode(Enum):
    FULL = "full"               # mic + system audio via Swift helper
    UNAVAILABLE = "unavailable" # helper binary not found — cannot record


@dataclass
class AudioPaths:
    """Paths to the captured audio files."""
    system: Path   # remote/system audio
    mic: Path      # local microphone


class AudioCapture:
    """Records microphone + system audio to WAV files via the Swift helper.

    Interface:
        capture = AudioCapture(output_path)
        mode = capture.start()
        paths = capture.stop()   # returns AudioPaths with .system and .mic
    """

    def __init__(self, output_path: Path):
        self._output_path = output_path
        self._process: Optional[subprocess.Popen] = None

    @property
    def _mic_path(self) -> Path:
        return self._output_path.with_stem(self._output_path.stem + "_mic")

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

    def stop(self) -> AudioPaths:
        """Stop recording. Returns AudioPaths with system and mic WAV files."""
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

        paths = AudioPaths(system=self._output_path, mic=self._mic_path)

        for label, p in [("system", paths.system), ("mic", paths.mic)]:
            if p.exists():
                size_kb = p.stat().st_size // 1024
                log.info(f"Audio [{label}]: {p.name} ({size_kb} KB)")
            else:
                log.warning(f"Audio [{label}]: {p.name} not found")

        if not paths.system.exists() and not paths.mic.exists():
            raise RuntimeError(
                f"audio-capture-helper produced no output files"
            )

        return paths
