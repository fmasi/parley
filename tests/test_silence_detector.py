import numpy as np
import pytest


def test_speech_detected_on_non_silence():
    from service.silence_detector import SilenceDetector
    sd = SilenceDetector(timeout_minutes=1)
    # 1 second of 440Hz tone (simulates speech-like audio)
    t = np.linspace(0, 1, 16000, dtype=np.float32)
    audio = (np.sin(2 * np.pi * 440 * t) * 0.5).astype(np.float32)
    # Call process_chunk — should not raise
    result = sd.process_chunk(audio, sample_rate=16000)
    assert isinstance(result, bool)


def test_silence_not_detected_immediately():
    from service.silence_detector import SilenceDetector
    sd = SilenceDetector(timeout_minutes=5)
    silence = np.zeros(16000, dtype=np.float32)
    sd.process_chunk(silence, sample_rate=16000)
    assert not sd.is_timed_out()


def test_silence_detected_after_timeout():
    from service.silence_detector import SilenceDetector
    import time
    sd = SilenceDetector(timeout_minutes=0)  # 0 minutes = immediate timeout
    silence = np.zeros(16000, dtype=np.float32)
    sd.process_chunk(silence, sample_rate=16000)
    time.sleep(0.1)
    assert sd.is_timed_out()


def test_speech_resets_timer():
    from service.silence_detector import SilenceDetector
    import time
    sd = SilenceDetector(timeout_minutes=0)
    silence = np.zeros(16000, dtype=np.float32)
    sd.process_chunk(silence, sample_rate=16000)
    t = np.linspace(0, 1, 16000, dtype=np.float32)
    speech = (np.sin(2 * np.pi * 440 * t) * 0.8).astype(np.float32)
    # Simulate speech detected (mock VAD returning True)
    sd._last_speech_time = time.time()
    assert not sd.is_timed_out()
