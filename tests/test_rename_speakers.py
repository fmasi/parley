# tests/test_rename_speakers.py
"""Tests for rename_speakers.py — mocks ffmpeg/afplay and stdin."""
import json
import pytest
from pathlib import Path
from unittest.mock import MagicMock, patch


# ---------------------------------------------------------------------------
# format_timestamp / format_timestamp_short (same logic as transcribe.py)
# ---------------------------------------------------------------------------

def test_format_timestamp_basic():
    from rename_speakers import format_timestamp
    assert format_timestamp(0.0) == "00:00:00,000"
    assert format_timestamp(90.25) == "00:01:30,250"


def test_format_timestamp_short_basic():
    from rename_speakers import format_timestamp_short
    assert format_timestamp_short(3600.0) == "01:00:00"


# ---------------------------------------------------------------------------
# find_speaker_samples
# ---------------------------------------------------------------------------

def test_find_speaker_samples_picks_longest(sample_segments):
    from rename_speakers import find_speaker_samples
    # Speaker 1 has segments: 0-2.5 (2.5s) and 5.1-8.0 (2.9s)
    # The longest should win
    samples = find_speaker_samples(sample_segments)
    assert "Speaker 1" in samples
    assert "Speaker 2" in samples
    # Speaker 1: second segment is 2.9s, first is 2.5s — second wins
    assert samples["Speaker 1"]["start"] == 5.1


def test_find_speaker_samples_respects_sample_duration(sample_segments):
    from rename_speakers import find_speaker_samples
    # With a tiny sample_duration the end should be clamped
    samples = find_speaker_samples(sample_segments, sample_duration=1.0)
    for speaker, s in samples.items():
        assert (s["end"] - s["start"]) <= 1.0 + 1e-6


def test_find_speaker_samples_ignores_unknown():
    from rename_speakers import find_speaker_samples
    segs = [
        {"start": 0.0, "end": 5.0, "speaker": "Unknown", "text": "mystery"},
        {"start": 5.0, "end": 10.0, "speaker": "", "text": "empty"},
        {"start": 0.0, "end": 3.0, "speaker": "Speaker 1", "text": "known"},
    ]
    samples = find_speaker_samples(segs)
    assert "Unknown" not in samples
    assert "" not in samples
    assert "Speaker 1" in samples


def test_find_speaker_samples_empty():
    from rename_speakers import find_speaker_samples
    assert find_speaker_samples([]) == {}


def test_find_speaker_samples_preserves_source(dual_stream_segments):
    from rename_speakers import find_speaker_samples
    samples = find_speaker_samples(dual_stream_segments)
    assert samples["Local Speaker"]["source"] == "local"
    assert samples["Remote Speaker"]["source"] == "remote"


def test_find_speaker_samples_source_none_when_missing():
    from rename_speakers import find_speaker_samples
    segs = [{"start": 0.0, "end": 3.0, "speaker": "Speaker 1", "text": "hi"}]
    samples = find_speaker_samples(segs)
    assert samples["Speaker 1"]["source"] is None


# ---------------------------------------------------------------------------
# apply_names
# ---------------------------------------------------------------------------

def test_apply_names_replaces_labels(sample_segments):
    from rename_speakers import apply_names
    name_map = {"Speaker 1": "Alice", "Speaker 2": "Bob"}
    result = apply_names(sample_segments, name_map)
    speakers = {seg["speaker"] for seg in result}
    assert speakers == {"Alice", "Bob"}


def test_apply_names_keeps_unmapped():
    from rename_speakers import apply_names
    segs = [{"start": 0.0, "end": 1.0, "speaker": "Speaker 3", "text": "hi"}]
    result = apply_names(segs, {"Speaker 1": "Alice"})
    assert result[0]["speaker"] == "Speaker 3"


def test_apply_names_does_not_mutate_original(sample_segments):
    from rename_speakers import apply_names
    original_speakers = [seg["speaker"] for seg in sample_segments]
    apply_names(sample_segments, {"Speaker 1": "Alice"})
    assert [seg["speaker"] for seg in sample_segments] == original_speakers


# ---------------------------------------------------------------------------
# write_txt
# ---------------------------------------------------------------------------

def test_write_txt(tmp_path, sample_segments):
    from rename_speakers import write_txt
    out = tmp_path / "out.txt"
    write_txt(sample_segments, str(out))
    content = out.read_text()
    assert "Speaker 1" in content
    assert "Hello there." in content


# ---------------------------------------------------------------------------
# write_srt
# ---------------------------------------------------------------------------

def test_write_srt(tmp_path, sample_segments):
    from rename_speakers import write_srt
    out = tmp_path / "out.srt"
    write_srt(sample_segments, str(out))
    content = out.read_text()
    assert "-->" in content
    assert "Speaker 1: Hello there." in content


# ---------------------------------------------------------------------------
# write_json
# ---------------------------------------------------------------------------

def test_write_json(tmp_path, sample_segments, sample_metadata):
    from rename_speakers import write_json
    out = tmp_path / "out.json"
    write_json(sample_segments, str(out), sample_metadata)
    data = json.loads(out.read_text())
    assert data["segments"] == sample_segments
    assert data["metadata"] == sample_metadata


# ---------------------------------------------------------------------------
# main() — integration
# ---------------------------------------------------------------------------

def test_main_renames_and_writes_txt(tmp_path, sample_json_transcript, sample_segments):
    from rename_speakers import main

    # Create a fake audio file referenced by the JSON
    audio = tmp_path / "meeting.wav"
    audio.write_bytes(b"fake")
    # Patch audio_paths in JSON metadata to point to our fake file
    data = json.loads(sample_json_transcript.read_text())
    data["metadata"]["audio_paths"] = [str(audio)]
    sample_json_transcript.write_text(json.dumps(data))

    with patch("rename_speakers.find_speaker_samples") as mock_samples, \
         patch("rename_speakers.prompt_speaker_names") as mock_prompt:
        mock_samples.return_value = {
            "Speaker 1": {"start": 0.0, "end": 2.5, "text": "Hello there."},
            "Speaker 2": {"start": 2.6, "end": 5.0, "text": "Hi, good to meet you."},
        }
        mock_prompt.return_value = {"Speaker 1": "Alice", "Speaker 2": "Bob"}

        with patch("sys.argv", ["rename_speakers.py", "-i", str(sample_json_transcript)]):
            main()

    txt_out = sample_json_transcript.with_suffix(".txt")
    assert txt_out.exists()
    content = txt_out.read_text()
    assert "Alice" in content
    assert "Bob" in content


def test_main_missing_json(tmp_path):
    from rename_speakers import main
    with patch("sys.argv", ["rename_speakers.py", "-i", str(tmp_path / "nope.json")]):
        with pytest.raises(SystemExit):
            main()


def test_main_no_speakers_exits(tmp_path, sample_json_transcript):
    from rename_speakers import main

    audio = tmp_path / "meeting.wav"
    audio.write_bytes(b"fake")
    data = json.loads(sample_json_transcript.read_text())
    # Remove all speaker labels so find_speaker_samples returns empty
    for seg in data["segments"]:
        seg["speaker"] = "Unknown"
    data["metadata"]["audio_paths"] = [str(audio)]
    sample_json_transcript.write_text(json.dumps(data))

    with patch("sys.argv", ["rename_speakers.py", "-i", str(sample_json_transcript)]):
        with pytest.raises(SystemExit):
            main()


def test_rename_dialog_reads_transcribe_metadata_format(tmp_path):
    """Contract test: rename_dialog must correctly parse metadata as written by transcribe.py."""
    from service.rename_dialog import run_rename_dialog

    audio = tmp_path / "system.wav"
    audio.write_bytes(b"fake")

    # This is the exact metadata format transcribe.py writes (lines 369-377)
    transcript = tmp_path / "recording.json"
    transcript.write_text(json.dumps({
        "segments": [
            {"start": 0.0, "end": 3.0, "speaker": "Remote SPEAKER_00", "text": "Hello"},
        ],
        "metadata": {
            "audio_files": ["system.wav", "mic.wav"],
            "audio_paths": [str(audio), str(tmp_path / "mic.wav")],
            "output_format": "txt",
            "language": "en",
            "dual_stream": True,
        },
    }))

    # Should resolve audio_paths[0] and find the file — not crash with "." path
    with patch("service.rename_dialog.find_speaker_samples") as mock_samples, \
         patch("service.rename_dialog._prompt_speaker") as mock_prompt:
        mock_samples.return_value = {
            "Remote SPEAKER_00": {"start": 0.0, "end": 3.0, "text": "Hello"},
        }
        mock_prompt.return_value = "Alice"
        run_rename_dialog(transcript)

    # Verify JSON was updated with speaker names
    result = json.loads(transcript.read_text())
    assert result["metadata"]["speaker_names"] == {"Remote SPEAKER_00": "Alice"}


def test_main_missing_audio(tmp_path, sample_json_transcript):
    from rename_speakers import main
    # audio_paths in metadata points to a file that does not exist
    data = json.loads(sample_json_transcript.read_text())
    data["metadata"]["audio_paths"] = [str(tmp_path / "missing.wav")]
    sample_json_transcript.write_text(json.dumps(data))

    with patch("sys.argv", ["rename_speakers.py", "-i", str(sample_json_transcript)]):
        with pytest.raises(SystemExit):
            main()


# ---------------------------------------------------------------------------
# rename_dialog — dual-stream audio routing
# ---------------------------------------------------------------------------

def test_rename_dialog_routes_local_speaker_to_mic_file(tmp_path):
    """Local-source speakers must use audio_paths[1] (mic file)."""
    from service.rename_dialog import run_rename_dialog

    system_wav = tmp_path / "system.wav"
    mic_wav = tmp_path / "mic.wav"
    system_wav.write_bytes(b"fake")
    mic_wav.write_bytes(b"fake")

    transcript = tmp_path / "recording.json"
    transcript.write_text(json.dumps({
        "segments": [
            {"start": 0.0, "end": 3.0, "speaker": "Local Speaker", "text": "hi", "source": "local"},
        ],
        "metadata": {
            "audio_files": ["system.wav", "mic.wav"],
            "audio_paths": [str(system_wav), str(mic_wav)],
            "output_format": "txt",
            "language": "en",
            "dual_stream": True,
        },
    }))

    captured_paths = []
    with patch("service.rename_dialog._prompt_speaker", side_effect=lambda spk, sample, path: captured_paths.append(path) or "Alice"):
        run_rename_dialog(transcript)

    assert len(captured_paths) == 1
    assert captured_paths[0] == str(mic_wav)


def test_rename_dialog_routes_remote_speaker_to_system_file(tmp_path):
    """Remote-source speakers must use audio_paths[0] (system audio file)."""
    from service.rename_dialog import run_rename_dialog

    system_wav = tmp_path / "system.wav"
    mic_wav = tmp_path / "mic.wav"
    system_wav.write_bytes(b"fake")
    mic_wav.write_bytes(b"fake")

    transcript = tmp_path / "recording.json"
    transcript.write_text(json.dumps({
        "segments": [
            {"start": 0.0, "end": 3.0, "speaker": "Remote Speaker", "text": "hello", "source": "remote"},
        ],
        "metadata": {
            "audio_files": ["system.wav", "mic.wav"],
            "audio_paths": [str(system_wav), str(mic_wav)],
            "output_format": "txt",
            "language": "en",
            "dual_stream": True,
        },
    }))

    captured_paths = []
    with patch("service.rename_dialog._prompt_speaker", side_effect=lambda spk, sample, path: captured_paths.append(path) or "Bob"):
        run_rename_dialog(transcript)

    assert len(captured_paths) == 1
    assert captured_paths[0] == str(system_wav)


def test_rename_dialog_single_stream_uses_same_file_for_all(tmp_path):
    """With only one audio file, all speakers use it regardless of source."""
    from service.rename_dialog import run_rename_dialog

    audio = tmp_path / "recording.wav"
    audio.write_bytes(b"fake")

    transcript = tmp_path / "recording.json"
    transcript.write_text(json.dumps({
        "segments": [
            {"start": 0.0, "end": 3.0, "speaker": "Speaker A", "text": "hi", "source": "local"},
            {"start": 3.0, "end": 6.0, "speaker": "Speaker B", "text": "hey", "source": "remote"},
        ],
        "metadata": {
            "audio_files": ["recording.wav"],
            "audio_paths": [str(audio)],
            "output_format": "txt",
            "language": "en",
            "dual_stream": False,
        },
    }))

    captured_paths = []
    with patch("service.rename_dialog._prompt_speaker", side_effect=lambda spk, sample, path: captured_paths.append(path) or spk):
        run_rename_dialog(transcript)

    assert len(captured_paths) == 2
    assert all(p == str(audio) for p in captured_paths)


def test_rename_dialog_source_defaults_to_remote_when_missing(tmp_path):
    """Segments without a source field fall back to the system audio file."""
    from service.rename_dialog import run_rename_dialog

    system_wav = tmp_path / "system.wav"
    mic_wav = tmp_path / "mic.wav"
    system_wav.write_bytes(b"fake")
    mic_wav.write_bytes(b"fake")

    transcript = tmp_path / "recording.json"
    transcript.write_text(json.dumps({
        "segments": [
            {"start": 0.0, "end": 3.0, "speaker": "Speaker X", "text": "hi"},  # no source
        ],
        "metadata": {
            "audio_paths": [str(system_wav), str(mic_wav)],
            "output_format": "txt",
        },
    }))

    captured_paths = []
    with patch("service.rename_dialog._prompt_speaker", side_effect=lambda spk, sample, path: captured_paths.append(path) or "X"):
        run_rename_dialog(transcript)

    assert captured_paths[0] == str(system_wav)
