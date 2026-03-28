"""Integration tests for the full pipeline flow.

These tests mock expensive operations (audio capture, transcription)
but test the real orchestration logic end-to-end.
"""
import json
import time
import pytest
from pathlib import Path
from unittest.mock import MagicMock, patch


def test_full_pipeline_flow(tmp_path):
    """Recording complete → transcription → rename callback triggered."""
    from service.config_manager import Config
    from service.pipeline import Pipeline

    config = Config(
        recording_directory=str(tmp_path),
        output_format="txt",
    )
    rename_calls = []

    def fake_subprocess_run(cmd, **kwargs):
        # Extract audio_path from command: ['python', 'transcribe.py', '-i', '<path>', '-f', '<fmt>']
        i_idx = cmd.index("-i")
        audio_path = Path(cmd[i_idx + 1])
        # Simulate transcribe.py writing JSON output
        json_path = audio_path.with_suffix(".json")
        json_path.write_text(json.dumps({
            "segments": [
                {"start": 0.0, "end": 5.0, "speaker": "SPEAKER_00", "text": "Hello"},
            ],
            "metadata": {
                "audio_paths": [str(audio_path)],
                "output_format": "txt",
            }
        }))
        return MagicMock(returncode=0, stdout="")

    pipeline = Pipeline(
        config=config,
        on_rename_ready=lambda p: rename_calls.append(p),
        on_error=lambda m: pytest.fail(f"Unexpected error: {m}"),
    )

    audio_path = tmp_path / "2026-03-27" / "meeting.m4a"
    audio_path.parent.mkdir(parents=True)
    audio_path.write_bytes(b"fake audio")

    with patch("service.pipeline.subprocess.run", side_effect=fake_subprocess_run):
        pipeline.on_recording_complete(audio_path)
        pipeline._queue.wait_all()

    assert len(rename_calls) == 1
    assert rename_calls[0].suffix == ".json"


def test_pipeline_error_recovery(tmp_path):
    """Transcription failure triggers error callback, not crash."""
    from service.config_manager import Config
    from service.pipeline import Pipeline

    config = Config(recording_directory=str(tmp_path), output_format="txt")
    errors = []

    pipeline = Pipeline(
        config=config,
        on_rename_ready=lambda p: pytest.fail("Should not reach rename"),
        on_error=lambda m: errors.append(m),
    )

    audio_path = tmp_path / "bad.m4a"
    audio_path.write_bytes(b"fake")

    with patch("service.pipeline.subprocess.run", side_effect=RuntimeError("GPU out of memory")):
        pipeline.on_recording_complete(audio_path)
        pipeline._queue.wait_all()

    assert len(errors) == 1
    assert "GPU out of memory" in errors[0]


def test_sequential_jobs_run_in_order(tmp_path):
    """Multiple recordings transcribe in FIFO order."""
    from service.config_manager import Config
    from service.pipeline import Pipeline

    config = Config(recording_directory=str(tmp_path), output_format="txt")
    completed = []

    def fake_subprocess_run(cmd, **kwargs):
        time.sleep(0.02)
        i_idx = cmd.index("-i")
        audio_path = Path(cmd[i_idx + 1])
        json_path = audio_path.with_suffix(".json")
        json_path.write_text(json.dumps({"segments": [], "metadata": {}}))
        return MagicMock(returncode=0, stdout="")

    pipeline = Pipeline(
        config=config,
        on_rename_ready=lambda p: completed.append(p.stem),
        on_error=lambda m: pytest.fail(m),
    )

    with patch("service.pipeline.subprocess.run", side_effect=fake_subprocess_run):
        for name in ["rec_a", "rec_b", "rec_c"]:
            path = tmp_path / f"{name}.m4a"
            path.write_bytes(b"audio")
            pipeline.on_recording_complete(path)

        pipeline._queue.wait_all()

    assert completed == ["rec_a", "rec_b", "rec_c"]
