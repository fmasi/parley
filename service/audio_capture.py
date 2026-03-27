"""Captures microphone audio using sounddevice (PortAudio / CoreAudio).

sounddevice wraps PortAudio which talks directly to CoreAudio, so no
PyObjC / ctypes juggling required. Records from the default input device
(built-in mic, AirPods mic, external USB mic, etc.).

Note: System audio capture (Zoom participants via headphones) requires a
virtual loopback device (e.g. BlackHole). Without one, only the microphone
input is captured.
"""
import threading
from pathlib import Path
from typing import List, Optional

import numpy as np

from service.logger import get_logger

log = get_logger("audio_capture")

try:
    import sounddevice as sd
    SOUNDDEVICE_AVAILABLE = True
except ImportError:
    sd = None  # type: ignore[assignment]
    SOUNDDEVICE_AVAILABLE = False
    log.warning("sounddevice not available — audio capture disabled")

try:
    import soundfile as sf
    SOUNDFILE_AVAILABLE = True
except ImportError:
    sf = None  # type: ignore[assignment]
    SOUNDFILE_AVAILABLE = False
    log.warning("soundfile not available — cannot write audio files")


SAMPLE_RATE = 16_000
CHANNELS = 1


class AudioCapture:
    """Records microphone input to a WAV file using sounddevice.

    Interface:
        capture = AudioCapture(output_path)
        capture.start()          # non-blocking
        path = capture.stop()    # blocks briefly, returns Path to WAV file
    """

    def __init__(self, output_path: Path):
        self._output_path = output_path
        self._chunks: List[np.ndarray] = []
        self._lock = threading.Lock()
        self._stream: Optional[object] = None

    def start(self) -> None:
        """Begin capturing mic audio. Non-blocking."""
        if not SOUNDDEVICE_AVAILABLE:
            log.error("Cannot start: sounddevice not installed")
            return

        self._chunks.clear()

        def _callback(indata, frames, time, status):
            if status:
                log.warning(f"sounddevice status: {status}")
            with self._lock:
                self._chunks.append(indata.copy())

        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="float32",
            callback=_callback,
        )
        self._stream.start()
        log.info(
            f"Recording started — device: {sd.query_devices(kind='input')['name']}, "
            f"{SAMPLE_RATE} Hz mono"
        )

    def stop(self) -> Path:
        """Stop capture and write audio to output_path. Returns path to WAV file."""
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None
            log.info("sounddevice stream stopped")

        return self._write_output()

    def _write_output(self) -> Path:
        with self._lock:
            audio = (
                np.concatenate(self._chunks, axis=0)
                if self._chunks
                else np.zeros((SAMPLE_RATE, CHANNELS), dtype=np.float32)
            )

        duration = len(audio) / SAMPLE_RATE
        if duration < 0.5:
            log.warning("Very short recording (<0.5s) — writing anyway")

        self._output_path.parent.mkdir(parents=True, exist_ok=True)

        if not SOUNDFILE_AVAILABLE:
            raise RuntimeError("soundfile is required to write audio files")

        sf.write(str(self._output_path), audio, SAMPLE_RATE)
        log.info(f"Audio written: {self._output_path.name} ({duration:.1f}s)")
        return self._output_path
