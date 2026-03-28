"""Tests for service/audio_capture.py.

AVFoundation is macOS-only; on other platforms the class degrades gracefully.
Tests that require AVFoundation are marked with @pytest.mark.macos.
"""
import pytest
from pathlib import Path
from unittest.mock import MagicMock, patch


def test_audio_capture_instantiates(tmp_path):
    """AudioCapture can be constructed on any platform."""
    from service.audio_capture import AudioCapture
    ac = AudioCapture(output_path=tmp_path / "out.wav")
    assert ac is not None


def test_audio_capture_start_noop_without_avfoundation(tmp_path):
    """start() is a no-op (logs error) when AVFoundation is unavailable."""
    from service.audio_capture import AudioCapture
    with patch("service.audio_capture.AVFOUNDATION_AVAILABLE", False):
        ac = AudioCapture(output_path=tmp_path / "out.wav")
        ac.start()  # Should not raise
        assert ac._recorder is None


def test_audio_capture_stop_raises_when_no_output(tmp_path):
    """stop() raises RuntimeError when no output file was produced."""
    from service.audio_capture import AudioCapture
    ac = AudioCapture(output_path=tmp_path / "nonexistent.wav")
    with pytest.raises(RuntimeError, match="did not produce output"):
        ac.stop()


@pytest.mark.macos
def test_audio_capture_records_to_wav(tmp_path):
    """start()/stop() round-trip with real AVFoundation writes a WAV file."""
    from service.audio_capture import AudioCapture, AVFOUNDATION_AVAILABLE
    if not AVFOUNDATION_AVAILABLE:
        pytest.skip("AVFoundation not available")
    import time
    ac = AudioCapture(output_path=tmp_path / "rec.wav")
    ac.start()
    time.sleep(0.5)
    result = ac.stop()
    assert result.exists()
    assert result.stat().st_size > 0
