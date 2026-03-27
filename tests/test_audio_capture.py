import numpy as np
import pytest
from pathlib import Path
from unittest.mock import MagicMock, patch


def test_audio_capture_creates_output_file(tmp_path):
    from service.audio_capture import AudioCapture
    output = tmp_path / "test_recording.m4a"
    ac = AudioCapture(output_path=output)
    with patch.object(ac, "_start_engine"), patch.object(ac, "_stop_engine"):
        with patch.object(ac, "_write_output", return_value=output) as mock_write:
            ac.start()
            result = ac.stop()
            mock_write.assert_called_once()
    assert result == output


def test_audio_capture_mixes_two_streams(tmp_path):
    from service.audio_capture import AudioCapture
    output = tmp_path / "mixed.m4a"
    ac = AudioCapture(output_path=output)
    mic = np.sin(np.linspace(0, 1, 16000)).astype(np.float32)
    sys = np.cos(np.linspace(0, 1, 16000)).astype(np.float32)
    mixed = ac._mix_streams(mic, sys)
    assert len(mixed) == 16000
    expected = (mic + sys) / 2.0
    np.testing.assert_array_almost_equal(mixed, expected)


def test_audio_capture_handles_mismatched_lengths(tmp_path):
    from service.audio_capture import AudioCapture
    ac = AudioCapture(output_path=tmp_path / "out.m4a")
    mic = np.ones(10000, dtype=np.float32)
    sys = np.ones(12000, dtype=np.float32)
    mixed = ac._mix_streams(mic, sys)
    assert len(mixed) == 10000  # truncates to shortest


def test_audio_capture_handles_missing_stream(tmp_path):
    from service.audio_capture import AudioCapture
    ac = AudioCapture(output_path=tmp_path / "out.m4a")
    mic = np.ones(10000, dtype=np.float32)
    mixed = ac._mix_streams(mic, np.array([], dtype=np.float32))
    assert len(mixed) == 10000
    np.testing.assert_array_equal(mixed, mic)
