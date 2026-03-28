"""Tests for service/audio_capture.py (Swift subprocess wrapper)."""
import signal
import pytest
from pathlib import Path
from unittest.mock import MagicMock, patch


def test_start_returns_unavailable_when_binary_missing(tmp_path):
    from service.audio_capture import AudioCapture, CaptureMode
    with patch("service.audio_capture.HELPER_BINARY", tmp_path / "nonexistent"):
        ac = AudioCapture(output_path=tmp_path / "out.wav")
        assert ac.start() == CaptureMode.UNAVAILABLE


def test_start_returns_full_when_binary_present(tmp_path):
    from service.audio_capture import AudioCapture, CaptureMode
    fake_bin = tmp_path / "audio-capture-helper"
    fake_bin.write_bytes(b"")

    mock_proc = MagicMock()
    with patch("service.audio_capture.HELPER_BINARY", fake_bin), \
         patch("service.audio_capture.subprocess.Popen", return_value=mock_proc):
        ac = AudioCapture(output_path=tmp_path / "out.wav")
        assert ac.start() == CaptureMode.FULL


def test_start_creates_parent_directory(tmp_path):
    from service.audio_capture import AudioCapture, CaptureMode
    fake_bin = tmp_path / "audio-capture-helper"
    fake_bin.write_bytes(b"")
    nested = tmp_path / "a" / "b" / "out.wav"

    mock_proc = MagicMock()
    with patch("service.audio_capture.HELPER_BINARY", fake_bin), \
         patch("service.audio_capture.subprocess.Popen", return_value=mock_proc):
        ac = AudioCapture(output_path=nested)
        ac.start()

    assert nested.parent.exists()


def test_stop_sends_sigterm(tmp_path):
    from service.audio_capture import AudioCapture, CaptureMode
    fake_bin = tmp_path / "audio-capture-helper"
    fake_bin.write_bytes(b"")
    out = tmp_path / "out.wav"
    out.write_bytes(b"RIFF")   # simulate output produced by helper

    mock_proc = MagicMock()
    mock_proc.returncode = 0
    mock_proc.communicate.return_value = ("", "")

    with patch("service.audio_capture.HELPER_BINARY", fake_bin), \
         patch("service.audio_capture.subprocess.Popen", return_value=mock_proc):
        ac = AudioCapture(output_path=out)
        ac.start()
        ac.stop()

    mock_proc.send_signal.assert_called_once_with(signal.SIGTERM)


def test_stop_raises_permission_error_on_exit_code_2(tmp_path):
    from service.audio_capture import AudioCapture
    fake_bin = tmp_path / "audio-capture-helper"
    fake_bin.write_bytes(b"")

    mock_proc = MagicMock()
    mock_proc.returncode = 2
    mock_proc.communicate.return_value = ("", "permission denied")

    with patch("service.audio_capture.HELPER_BINARY", fake_bin), \
         patch("service.audio_capture.subprocess.Popen", return_value=mock_proc):
        ac = AudioCapture(output_path=tmp_path / "out.wav")
        ac.start()
        with pytest.raises(PermissionError, match="permission denied"):
            ac.stop()


def test_stop_raises_when_no_output_file(tmp_path):
    from service.audio_capture import AudioCapture
    fake_bin = tmp_path / "audio-capture-helper"
    fake_bin.write_bytes(b"")

    mock_proc = MagicMock()
    mock_proc.returncode = 0
    mock_proc.communicate.return_value = ("", "")

    with patch("service.audio_capture.HELPER_BINARY", fake_bin), \
         patch("service.audio_capture.subprocess.Popen", return_value=mock_proc):
        ac = AudioCapture(output_path=tmp_path / "out.wav")
        ac.start()
        with pytest.raises(RuntimeError, match="did not produce output"):
            ac.stop()


def test_stop_returns_output_path_on_success(tmp_path):
    from service.audio_capture import AudioCapture
    fake_bin = tmp_path / "audio-capture-helper"
    fake_bin.write_bytes(b"")
    out = tmp_path / "out.wav"
    out.write_bytes(b"RIFF")

    mock_proc = MagicMock()
    mock_proc.returncode = 0
    mock_proc.communicate.return_value = ("", "")

    with patch("service.audio_capture.HELPER_BINARY", fake_bin), \
         patch("service.audio_capture.subprocess.Popen", return_value=mock_proc):
        ac = AudioCapture(output_path=out)
        ac.start()
        result = ac.stop()

    assert result == out


def test_stop_is_noop_when_not_started(tmp_path):
    from service.audio_capture import AudioCapture
    out = tmp_path / "out.wav"
    out.write_bytes(b"RIFF")
    ac = AudioCapture(output_path=out)
    # stop() without start() should not raise
    result = ac.stop()
    assert result == out
