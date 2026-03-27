"""Silero VAD-based silence detector.

Only triggers timeout when no human speech is detected — ignores
typing, AC noise, and other background sounds.
"""
import time
from typing import Optional

import numpy as np
import torch


class SilenceDetector:
    """Detects human speech using Silero VAD.

    Usage:
        detector = SilenceDetector(timeout_minutes=5)
        detector.process_chunk(audio_array, sample_rate=16000)
        if detector.is_timed_out():
            show_stop_prompt()
    """

    SPEECH_THRESHOLD = 0.5

    def __init__(self, timeout_minutes: int = 5):
        self._timeout_seconds = timeout_minutes * 60
        self._last_speech_time: float = time.time()
        self._model = None  # Lazy load on first use

    def _load_model(self):
        if self._model is None:
            self._model, self._utils = torch.hub.load(
                repo_or_dir="snakers4/silero-vad",
                model="silero_vad",
                force_reload=False,
                trust_repo=True,
            )

    def process_chunk(self, audio: np.ndarray, sample_rate: int = 16000) -> bool:
        """Process one audio chunk. Returns True if speech detected.

        audio: float32 numpy array, values in [-1.0, 1.0]
        sample_rate: must be 8000 or 16000 for Silero VAD

        Silero VAD requires fixed window sizes: 512 samples at 16000 Hz,
        256 samples at 8000 Hz. Longer arrays are split into windows;
        returns True if any window exceeds the speech threshold.
        """
        self._load_model()
        window_size = 512 if sample_rate == 16000 else 256
        speech_detected = False
        for start in range(0, len(audio) - window_size + 1, window_size):
            window = audio[start : start + window_size]
            tensor = torch.FloatTensor(window).unsqueeze(0)
            speech_prob = self._model(tensor, sample_rate).item()
            if speech_prob > self.SPEECH_THRESHOLD:
                speech_detected = True
                break
        if speech_detected:
            self._last_speech_time = time.time()
        return speech_detected

    # Minimum elapsed seconds before a timeout can fire. Prevents false
    # positives on the sub-millisecond scale when timeout_minutes=0.
    _MIN_TIMEOUT_SECONDS = 0.05

    def is_timed_out(self) -> bool:
        """Returns True if no speech detected for timeout_minutes."""
        threshold = max(self._timeout_seconds, self._MIN_TIMEOUT_SECONDS)
        return (time.time() - self._last_speech_time) > threshold

    def reset(self):
        """Call when recording starts to reset the timer."""
        self._last_speech_time = time.time()
