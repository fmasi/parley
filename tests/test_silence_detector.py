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


def test_process_chunk_8khz_window():
    """At 8 kHz the window size must be 256 samples."""
    from service.silence_detector import SilenceDetector
    sd = SilenceDetector(timeout_minutes=5)
    captured_sizes = []

    def fake_model(tensor, sr):
        captured_sizes.append(tensor.shape[-1])
        return MagicMock(item=MagicMock(return_value=0.0))

    sd._model = fake_model
    audio = np.zeros(512, dtype=np.float32)  # two 256-sample windows
    sd.process_chunk(audio, sample_rate=8000)
    assert all(s == 256 for s in captured_sizes)


def test_process_chunk_returns_false_below_threshold():
    sd = _make_detector(timeout_minutes=5, speech_prob=0.49)
    audio = np.zeros(512, dtype=np.float32)
    assert sd.process_chunk(audio, sample_rate=16000) is False


def test_process_chunk_returns_true_at_threshold():
    sd = _make_detector(timeout_minutes=5, speech_prob=0.51)
    audio = np.zeros(512, dtype=np.float32)
    assert sd.process_chunk(audio, sample_rate=16000) is True


def test_reset_clears_timer():
    sd = _make_detector(timeout_minutes=0, speech_prob=0.1)
    # Force timer into the past
    sd._last_speech_time = time.time() - 10
    sd.reset()
    assert not sd.is_timed_out()


def test_process_chunk_short_audio_no_full_window():
    """Audio shorter than one window should be processed without error."""
    from service.silence_detector import SilenceDetector
    sd = SilenceDetector(timeout_minutes=5)
    sd._model = MagicMock(return_value=MagicMock(item=MagicMock(return_value=0.0)))
    short = np.zeros(100, dtype=np.float32)  # less than 256 or 512
    result = sd.process_chunk(short, sample_rate=16000)
    assert result is False  # no windows processed → no speech
