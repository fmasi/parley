"""Captures microphone + system audio using AVAudioEngine (CoreAudio via PyObjC).

Requires macOS 12.0+ and Screen Recording permission.
System audio capture via outputNode tap works with Screen Recording permission
granted at OS level — no virtual audio device (BlackHole) needed.
"""
import ctypes
import threading
from pathlib import Path
from typing import List, Optional

import numpy as np

from service.logger import get_logger

try:
    import soundfile as sf
    SOUNDFILE_AVAILABLE = True
except ImportError:
    sf = None  # type: ignore[assignment]
    SOUNDFILE_AVAILABLE = False

log = get_logger("audio_capture")

try:
    import objc
    import AVFoundation as AVF
    AVFOUNDATION_AVAILABLE = True
except ImportError:
    AVFOUNDATION_AVAILABLE = False
    log.warning("AVFoundation not available — audio capture disabled")


SAMPLE_RATE = 16000
BUFFER_SIZE = 4096


class AudioCapture:
    """Records mic + system audio simultaneously using AVAudioEngine.

    Interface contract (for future refactoring):
        capture = AudioCapture(output_path)
        capture.start()
        # ... time passes ...
        path = capture.stop()  # returns Path to written file

    Internal methods prefixed with _ are replaceable without changing callers.
    """

    def __init__(self, output_path: Path):
        self._output_path = output_path
        self._mic_chunks: List[np.ndarray] = []
        self._sys_chunks: List[np.ndarray] = []
        self._lock = threading.Lock()
        self._engine: Optional[object] = None

    def start(self) -> None:
        """Begin capturing audio. Non-blocking."""
        self._mic_chunks.clear()
        self._sys_chunks.clear()
        if AVFOUNDATION_AVAILABLE:
            self._start_engine()
        else:
            log.error("Cannot start: AVFoundation not available")

    def stop(self) -> Path:
        """Stop capture and write mixed audio to output_path."""
        if AVFOUNDATION_AVAILABLE:
            self._stop_engine()
        return self._write_output()

    def _start_engine(self) -> None:
        self._engine = AVF.AVAudioEngine.alloc().init()
        fmt = self._engine.inputNode().outputFormatForBus_(0)

        def mic_tap(buffer, time):
            with self._lock:
                self._mic_chunks.append(self._buffer_to_numpy(buffer))

        def sys_tap(buffer, time):
            with self._lock:
                self._sys_chunks.append(self._buffer_to_numpy(buffer))

        self._engine.inputNode().installTapOnBus_bufferSize_format_block_(
            0, BUFFER_SIZE, fmt, mic_tap
        )
        self._engine.outputNode().installTapOnBus_bufferSize_format_block_(
            0, BUFFER_SIZE, fmt, sys_tap
        )

        error = objc.nil
        success = self._engine.startAndReturnError_(error)
        if not success:
            log.error("AVAudioEngine failed to start — check Screen Recording permission")

    def _stop_engine(self) -> None:
        if self._engine:
            self._engine.inputNode().removeTapOnBus_(0)
            self._engine.outputNode().removeTapOnBus_(0)
            self._engine.stop()

    @staticmethod
    def _buffer_to_numpy(buffer) -> np.ndarray:
        """Extract float32 PCM samples from AVAudioPCMBuffer."""
        frame_count = int(buffer.frameLength())
        channel_data = buffer.floatChannelData()
        if channel_data is None or frame_count == 0:
            return np.array([], dtype=np.float32)
        ptr = ctypes.cast(channel_data[0], ctypes.POINTER(ctypes.c_float))
        return np.ctypeslib.as_array(ptr, shape=(frame_count,)).copy()

    def _mix_streams(
        self, mic: np.ndarray, sys: np.ndarray
    ) -> np.ndarray:
        """Mix two audio streams. Handles mismatched lengths and empty streams."""
        if len(mic) == 0:
            return sys
        if len(sys) == 0:
            return mic
        min_len = min(len(mic), len(sys))
        return ((mic[:min_len] + sys[:min_len]) / 2.0).astype(np.float32)

    def _write_output(self) -> Path:
        with self._lock:
            mic = np.concatenate(self._mic_chunks) if self._mic_chunks else np.array([], dtype=np.float32)
            sys = np.concatenate(self._sys_chunks) if self._sys_chunks else np.array([], dtype=np.float32)

        mixed = self._mix_streams(mic, sys)

        if len(mixed) == 0:
            log.warning("No audio captured — writing silent file")
            mixed = np.zeros(SAMPLE_RATE, dtype=np.float32)

        self._output_path.parent.mkdir(parents=True, exist_ok=True)
        if not SOUNDFILE_AVAILABLE:
            raise RuntimeError("soundfile package is required to write audio files")
        sf.write(str(self._output_path), mixed, SAMPLE_RATE)
        log.info(f"Audio written: {self._output_path} ({len(mixed)/SAMPLE_RATE:.1f}s)")
        return self._output_path
