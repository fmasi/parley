# tests/test_transcribe.py
"""Tests for transcribe.py — mocks mlx_whisper, pyannote, torch, and subprocess."""
import json
import sys
import pytest
from pathlib import Path
from unittest.mock import MagicMock, patch


# ---------------------------------------------------------------------------
# format_timestamp / format_timestamp_short
# ---------------------------------------------------------------------------

def test_format_timestamp_zero():
    from transcribe import format_timestamp
    assert format_timestamp(0.0) == "00:00:00,000"


def test_format_timestamp_hours():
    from transcribe import format_timestamp
    assert format_timestamp(3661.5) == "01:01:01,500"


def test_format_timestamp_short():
    from transcribe import format_timestamp_short
    assert format_timestamp_short(3661.9) == "01:01:01"


def test_format_timestamp_milliseconds():
    from transcribe import format_timestamp
    assert format_timestamp(0.123) == "00:00:00,123"


# ---------------------------------------------------------------------------
# deduplicate_segments
# ---------------------------------------------------------------------------

def test_deduplicate_removes_zero_duration():
    from transcribe import deduplicate_segments
    segs = [{"start": 1.0, "end": 1.0, "text": "echo"}]
    assert deduplicate_segments(segs) == []


def test_deduplicate_removes_consecutive_duplicates():
    from transcribe import deduplicate_segments
    segs = [
        {"start": 0.0, "end": 1.0, "text": "  hello  "},
        {"start": 1.0, "end": 2.0, "text": "hello"},
    ]
    result = deduplicate_segments(segs)
    assert len(result) == 1
    assert result[0]["start"] == 0.0


def test_deduplicate_keeps_different_segments():
    from transcribe import deduplicate_segments
    segs = [
        {"start": 0.0, "end": 1.0, "text": "hello"},
        {"start": 1.0, "end": 2.0, "text": "world"},
    ]
    assert len(deduplicate_segments(segs)) == 2


def test_deduplicate_empty():
    from transcribe import deduplicate_segments
    assert deduplicate_segments([]) == []


# ---------------------------------------------------------------------------
# assign_speakers
# ---------------------------------------------------------------------------

def test_assign_speakers_basic_overlap():
    from transcribe import assign_speakers
    whisper = [{"start": 0.0, "end": 2.0, "text": "Hello"}]
    diarize = [{"start": 0.0, "end": 2.0, "speaker": "SPEAKER_00"}]
    result = assign_speakers(whisper, diarize)
    assert result[0]["speaker"] == "Speaker 1"
    assert result[0]["text"] == "Hello"


def test_assign_speakers_unknown_when_no_overlap():
    from transcribe import assign_speakers
    whisper = [{"start": 10.0, "end": 12.0, "text": "Nobody"}]
    diarize = [{"start": 0.0, "end": 2.0, "speaker": "SPEAKER_00"}]
    result = assign_speakers(whisper, diarize)
    assert result[0]["speaker"] == "Unknown"


def test_assign_speakers_consistent_mapping():
    from transcribe import assign_speakers
    whisper = [
        {"start": 0.0, "end": 1.0, "text": "A"},
        {"start": 2.0, "end": 3.0, "text": "B"},
    ]
    diarize = [
        {"start": 0.0, "end": 1.0, "speaker": "SPEAKER_00"},
        {"start": 2.0, "end": 3.0, "speaker": "SPEAKER_01"},
    ]
    result = assign_speakers(whisper, diarize)
    assert result[0]["speaker"] == "Speaker 1"
    assert result[1]["speaker"] == "Speaker 2"


def test_assign_speakers_same_speaker_maps_consistently():
    from transcribe import assign_speakers
    whisper = [
        {"start": 0.0, "end": 1.0, "text": "First"},
        {"start": 5.0, "end": 6.0, "text": "Second"},
    ]
    diarize = [
        {"start": 0.0, "end": 1.0, "speaker": "SPEAKER_00"},
        {"start": 5.0, "end": 6.0, "speaker": "SPEAKER_00"},
    ]
    result = assign_speakers(whisper, diarize)
    assert result[0]["speaker"] == result[1]["speaker"] == "Speaker 1"


def test_assign_speakers_empty():
    from transcribe import assign_speakers
    assert assign_speakers([], []) == []


# ---------------------------------------------------------------------------
# write_txt
# ---------------------------------------------------------------------------

def test_write_txt(tmp_path, sample_segments):
    from transcribe import write_txt
    out = tmp_path / "out.txt"
    write_txt(sample_segments, str(out))
    content = out.read_text()
    assert "Speaker 1" in content
    assert "Hello there." in content
    assert "[00:00:00]" in content


def test_write_txt_no_speaker(tmp_path):
    from transcribe import write_txt
    segs = [{"start": 0.0, "end": 1.0, "speaker": "", "text": "No label"}]
    out = tmp_path / "out.txt"
    write_txt(segs, str(out))
    content = out.read_text()
    assert "No label" in content
    assert ": " not in content  # no speaker prefix


# ---------------------------------------------------------------------------
# write_srt
# ---------------------------------------------------------------------------

def test_write_srt(tmp_path, sample_segments):
    from transcribe import write_srt
    out = tmp_path / "out.srt"
    write_srt(sample_segments, str(out))
    content = out.read_text()
    assert "1\n" in content
    assert "-->" in content
    assert "Speaker 1: Hello there." in content


def test_write_srt_sequential_indices(tmp_path, sample_segments):
    from transcribe import write_srt
    out = tmp_path / "out.srt"
    write_srt(sample_segments, str(out))
    lines = out.read_text().splitlines()
    indices = [l for l in lines if l.strip().isdigit()]
    assert indices == ["1", "2", "3"]


# ---------------------------------------------------------------------------
# write_json
# ---------------------------------------------------------------------------

def test_write_json(tmp_path, sample_segments, sample_metadata):
    from transcribe import write_json
    out = tmp_path / "out.json"
    write_json(sample_segments, str(out), sample_metadata)
    data = json.loads(out.read_text())
    assert data["metadata"] == sample_metadata
    assert len(data["segments"]) == 3
    assert data["segments"][0]["text"] == "Hello there."


# ---------------------------------------------------------------------------
# main() — integration via mocked ML models
# ---------------------------------------------------------------------------

def test_main_txt_output(tmp_path):
    from transcribe import main
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"fake")

    fake_result = {
        "segments": [{"start": 0.0, "end": 1.0, "text": "hello"}],
        "language": "en",
    }
    mock_transcribe = MagicMock(return_value=fake_result)
    mock_diarize = MagicMock(return_value=[{"start": 0.0, "end": 1.0, "speaker": "SPEAKER_00"}])

    with patch("transcribe.transcribe_audio", mock_transcribe), \
         patch("transcribe.diarize_audio", mock_diarize), \
         patch("sys.argv", ["transcribe.py", "-i", str(audio), "-f", "txt",
                            "--hf-token", "fake_token"]):
        main()

    txt = audio.with_suffix(".txt")
    assert txt.exists()
    assert "hello" in txt.read_text()
    json_out = audio.with_suffix(".json")
    assert json_out.exists()


def test_main_no_diarize(tmp_path):
    from transcribe import main
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"fake")

    fake_result = {
        "segments": [{"start": 0.0, "end": 1.0, "text": "solo"}],
        "language": "en",
    }
    mock_transcribe = MagicMock(return_value=fake_result)

    with patch("transcribe.transcribe_audio", mock_transcribe), \
         patch("sys.argv", ["transcribe.py", "-i", str(audio), "--no-diarize"]):
        main()

    txt = audio.with_suffix(".txt")
    assert "solo" in txt.read_text()


def test_main_missing_file(tmp_path):
    from transcribe import main
    with patch("sys.argv", ["transcribe.py", "-i", str(tmp_path / "nope.wav")]):
        with pytest.raises(SystemExit):
            main()


def test_main_missing_hf_token(tmp_path):
    from transcribe import main
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"fake")
    with patch("sys.argv", ["transcribe.py", "-i", str(audio)]), \
         patch.dict("os.environ", {}, clear=True):
        # Remove HF_TOKEN if present
        import os
        os.environ.pop("HF_TOKEN", None)
        with pytest.raises(SystemExit):
            main()


def test_main_srt_output(tmp_path):
    from transcribe import main
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"fake")

    fake_result = {
        "segments": [{"start": 0.0, "end": 1.0, "text": "subtitle"}],
        "language": "en",
    }
    mock_transcribe = MagicMock(return_value=fake_result)
    mock_diarize = MagicMock(return_value=[{"start": 0.0, "end": 1.0, "speaker": "SPEAKER_00"}])

    with patch("transcribe.transcribe_audio", mock_transcribe), \
         patch("transcribe.diarize_audio", mock_diarize), \
         patch("sys.argv", ["transcribe.py", "-i", str(audio), "-f", "srt",
                            "--hf-token", "fake_token"]):
        main()

    srt = audio.with_suffix(".srt")
    assert srt.exists()
    assert "-->" in srt.read_text()


def test_main_json_output(tmp_path):
    from transcribe import main
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"fake")

    fake_result = {
        "segments": [{"start": 0.0, "end": 1.0, "text": "data"}],
        "language": "en",
    }
    mock_transcribe = MagicMock(return_value=fake_result)
    mock_diarize = MagicMock(return_value=[{"start": 0.0, "end": 1.0, "speaker": "SPEAKER_00"}])

    with patch("transcribe.transcribe_audio", mock_transcribe), \
         patch("transcribe.diarize_audio", mock_diarize), \
         patch("sys.argv", ["transcribe.py", "-i", str(audio), "-f", "json",
                            "--hf-token", "fake_token"]):
        main()

    json_out = audio.with_suffix(".json")
    data = json.loads(json_out.read_text())
    assert data["segments"][0]["text"] == "data"


# ---------------------------------------------------------------------------
# transcribe_dual_stream()
# ---------------------------------------------------------------------------

def test_transcribe_dual_stream_tags_segments_with_source(tmp_path):
    from transcribe import transcribe_dual_stream
    sys_audio = tmp_path / "system.wav"
    mic_audio = tmp_path / "mic.wav"
    sys_audio.write_bytes(b"x" * 100)  # > 44 bytes
    mic_audio.write_bytes(b"x" * 100)

    fake_sys_result = {
        "segments": [{"start": 0.0, "end": 2.0, "text": "remote words"}],
        "language": "en",
    }
    fake_mic_result = {
        "segments": [{"start": 1.0, "end": 3.0, "text": "local words"}],
        "language": "en",
    }
    fake_diarize = [{"start": 0.0, "end": 3.0, "speaker": "SPEAKER_00"}]

    with patch("transcribe.transcribe_audio", side_effect=[fake_sys_result, fake_mic_result]), \
         patch("transcribe.diarize_audio", return_value=fake_diarize):
        segments = transcribe_dual_stream(
            system_path=str(sys_audio),
            mic_path=str(mic_audio),
            hf_token="fake",
            num_speakers=None,
            language=None,
            no_diarize=False,
        )

    assert len(segments) == 2
    # Each segment must have a 'source' field
    sources = {s["source"] for s in segments}
    assert sources == {"local", "remote"}
    # Speaker names should be prefixed
    remote_seg = [s for s in segments if s["source"] == "remote"][0]
    local_seg = [s for s in segments if s["source"] == "local"][0]
    assert remote_seg["speaker"].startswith("Remote")
    assert local_seg["speaker"].startswith("Local")


def test_transcribe_dual_stream_merges_chronologically(tmp_path):
    from transcribe import transcribe_dual_stream
    sys_audio = tmp_path / "system.wav"
    mic_audio = tmp_path / "mic.wav"
    sys_audio.write_bytes(b"x" * 100)
    mic_audio.write_bytes(b"x" * 100)

    fake_sys_result = {
        "segments": [
            {"start": 0.0, "end": 1.0, "text": "first"},
            {"start": 4.0, "end": 5.0, "text": "third"},
        ],
        "language": "en",
    }
    fake_mic_result = {
        "segments": [{"start": 2.0, "end": 3.0, "text": "second"}],
        "language": "en",
    }

    with patch("transcribe.transcribe_audio", side_effect=[fake_sys_result, fake_mic_result]):
        segments = transcribe_dual_stream(
            system_path=str(sys_audio),
            mic_path=str(mic_audio),
            hf_token=None,
            num_speakers=None,
            language=None,
            no_diarize=True,
        )

    assert len(segments) == 3
    starts = [s["start"] for s in segments]
    assert starts == sorted(starts), "Segments must be sorted chronologically"


def test_transcribe_dual_stream_skips_missing_file(tmp_path):
    from transcribe import transcribe_dual_stream
    sys_audio = tmp_path / "system.wav"
    sys_audio.write_bytes(b"x" * 100)
    mic_audio = tmp_path / "mic_missing.wav"  # does not exist

    fake_result = {
        "segments": [{"start": 0.0, "end": 1.0, "text": "only system"}],
        "language": "en",
    }

    with patch("transcribe.transcribe_audio", return_value=fake_result) as mock_ta:
        segments = transcribe_dual_stream(
            system_path=str(sys_audio),
            mic_path=str(mic_audio),
            hf_token=None,
            num_speakers=None,
            language=None,
            no_diarize=True,
        )

    mock_ta.assert_called_once()  # only transcribed system audio
    assert len(segments) == 1
    assert segments[0]["source"] == "remote"


def test_transcribe_dual_stream_skips_empty_file(tmp_path):
    from transcribe import transcribe_dual_stream
    sys_audio = tmp_path / "system.wav"
    mic_audio = tmp_path / "mic.wav"
    sys_audio.write_bytes(b"x" * 100)
    mic_audio.write_bytes(b"x" * 44)  # WAV header only — should be skipped

    fake_result = {
        "segments": [{"start": 0.0, "end": 1.0, "text": "system only"}],
        "language": "en",
    }

    with patch("transcribe.transcribe_audio", return_value=fake_result) as mock_ta:
        segments = transcribe_dual_stream(
            system_path=str(sys_audio),
            mic_path=str(mic_audio),
            hf_token=None,
            num_speakers=None,
            language=None,
            no_diarize=True,
        )

    mock_ta.assert_called_once()
    assert len(segments) == 1
    assert segments[0]["source"] == "remote"


def test_main_dual_input_mode(tmp_path):
    from transcribe import main
    sys_audio = tmp_path / "system.wav"
    mic_audio = tmp_path / "mic.wav"
    sys_audio.write_bytes(b"x" * 100)
    mic_audio.write_bytes(b"x" * 100)

    fake_result = {
        "segments": [{"start": 0.0, "end": 1.0, "text": "hello"}],
        "language": "en",
    }

    with patch("transcribe.transcribe_audio", return_value=fake_result), \
         patch("transcribe.diarize_audio", return_value=[{"start": 0.0, "end": 1.0, "speaker": "SPEAKER_00"}]), \
         patch("sys.argv", ["transcribe.py",
                            "-i", str(sys_audio), "-i", str(mic_audio),
                            "--hf-token", "fake_token"]):
        main()

    txt = sys_audio.with_suffix(".txt")
    assert txt.exists()
    json_out = sys_audio.with_suffix(".json")
    assert json_out.exists()
    data = json.loads(json_out.read_text())
    assert data["metadata"]["dual_stream"] is True
