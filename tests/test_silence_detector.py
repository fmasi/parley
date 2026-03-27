import time
import numpy as np
import pytest
from unittest.mock import MagicMock, patch


def _make_detector(timeout_minutes, speech_prob=0.0):
    """Create a SilenceDetector with a mocked VAD model."""
    from service.silence_detector import SilenceDetector
    sd = SilenceDetector(timeout_minutes=timeout_minutes)
    mock_model = MagicMock(return_value=MagicMock(item=MagicMock(return_value=speech_prob)))
    sd._model = mock_model
    return sd


def test_speech_detected_on_non_silence():
    sd = _make_detector(timeout_minutes=1, speech_prob=0.9)
    t = np.linspace(0, 1, 16000, dtype=np.float32)
    audio = (np.sin(2 * np.pi * 440 * t) * 0.5).astype(np.float32)
    result = sd.process_chunk(audio, sample_rate=16000)
    assert result is True


def test_silence_not_detected_immediately():
    sd = _make_detector(timeout_minutes=5, speech_prob=0.1)
    silence = np.zeros(16000, dtype=np.float32)
    sd.process_chunk(silence, sample_rate=16000)
    assert not sd.is_timed_out()


def test_silence_detected_after_timeout():
    sd = _make_detector(timeout_minutes=0, speech_prob=0.1)
    silence = np.zeros(16000, dtype=np.float32)
    sd.process_chunk(silence, sample_rate=16000)
    time.sleep(0.1)
    assert sd.is_timed_out()


def test_speech_resets_timer():
    sd = _make_detector(timeout_minutes=0, speech_prob=0.1)
    silence = np.zeros(16000, dtype=np.float32)
    sd.process_chunk(silence, sample_rate=16000)
    # Now simulate speech detected
    sd._last_speech_time = time.time()
    assert not sd.is_timed_out()
