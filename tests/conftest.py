"""Shared pytest fixtures for audio-transcribe tests."""
import json
import numpy as np
import pytest


@pytest.fixture
def sample_segments():
    """A minimal list of transcript segments with speaker labels."""
    return [
        {"start": 0.0, "end": 2.5, "speaker": "Speaker 1", "text": "Hello there."},
        {"start": 2.6, "end": 5.0, "speaker": "Speaker 2", "text": "Hi, good to meet you."},
        {"start": 5.1, "end": 8.0, "speaker": "Speaker 1", "text": "Let us get started."},
    ]


@pytest.fixture
def dual_stream_segments():
    """Transcript segments with source field (local=mic, remote=system audio)."""
    return [
        {"start": 0.0, "end": 5.0, "speaker": "Local Speaker", "text": "I am on the mic.", "source": "local"},
        {"start": 5.1, "end": 9.0, "speaker": "Remote Speaker", "text": "I am on the system audio.", "source": "remote"},
        {"start": 9.1, "end": 11.0, "speaker": "Local Speaker", "text": "Back to me.", "source": "local"},
    ]


@pytest.fixture
def sample_metadata():
    """Typical metadata block written by transcribe.py."""
    return {
        "audio_files": ["meeting.wav"],
        "audio_paths": ["/tmp/meeting.wav"],
        "output_format": "txt",
        "language": "en",
        "num_speakers": 2,
        "diarization": True,
    }


@pytest.fixture
def sample_json_transcript(tmp_path, sample_segments, sample_metadata):
    """A JSON transcript file on disk."""
    path = tmp_path / "meeting.json"
    path.write_text(
        json.dumps({"metadata": sample_metadata, "segments": sample_segments}),
        encoding="utf-8",
    )
    return path


@pytest.fixture
def sample_audio_array():
    """A short float32 audio array at 16 kHz (1 second of silence)."""
    return np.zeros(16000, dtype=np.float32)


@pytest.fixture
def sine_audio_array():
    """A short float32 audio array containing a 440 Hz tone at 16 kHz."""
    t = np.linspace(0, 1, 16000, dtype=np.float32)
    return (np.sin(2 * np.pi * 440 * t) * 0.5).astype(np.float32)
