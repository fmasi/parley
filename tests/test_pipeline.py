# tests/test_pipeline.py
import json
import time
import pytest
from pathlib import Path
from unittest.mock import MagicMock, patch, call


def test_pipeline_enqueues_job_on_recording_complete(tmp_path):
    from service.pipeline import Pipeline
    from service.config_manager import Config

    config = Config(recording_directory=str(tmp_path), output_format="txt")
    on_rename = MagicMock()

    with patch("service.pipeline.subprocess.run") as mock_run:
        # Simulate transcribe.py writing JSON output
        def fake_transcribe(*args, **kwargs):
            audio_path = Path(args[0][3])  # value after -i flag
            json_path = audio_path.with_suffix(".json")
            json_path.write_text(json.dumps({"segments": [], "metadata": {}}))
            return MagicMock(returncode=0, stdout="")
        mock_run.side_effect = fake_transcribe

        pipeline = Pipeline(config=config, on_rename_ready=on_rename)
        audio_file = tmp_path / "2026-03-27" / "test.m4a"
        audio_file.parent.mkdir(parents=True)
        audio_file.write_bytes(b"fake audio")

        pipeline.on_recording_complete(audio_file)
        pipeline._queue.wait_all()

    on_rename.assert_called_once()
    called_with_path = on_rename.call_args[0][0]
    assert called_with_path.suffix == ".json"


def test_pipeline_calls_on_error_on_transcription_failure(tmp_path):
    from service.pipeline import Pipeline
    from service.config_manager import Config

    config = Config(recording_directory=str(tmp_path), output_format="txt")
    errors = []

    with patch("service.pipeline.subprocess.run", side_effect=RuntimeError("crash")):
        pipeline = Pipeline(
            config=config,
            on_rename_ready=MagicMock(),
            on_error=lambda msg: errors.append(msg),
        )
        audio_file = tmp_path / "bad.m4a"
        audio_file.write_bytes(b"fake")
        pipeline.on_recording_complete(audio_file)
        pipeline._queue.wait_all()

    assert len(errors) == 1
    assert "crash" in errors[0]


def test_pipeline_generates_correct_filename(tmp_path):
    from service.pipeline import Pipeline
    from service.config_manager import Config

    config = Config(recording_directory=str(tmp_path), output_format="srt")
    pipeline = Pipeline(config=config, on_rename_ready=MagicMock())
    cmd = pipeline._build_transcribe_command(tmp_path / "meeting.m4a")
    assert "-i" in cmd
    assert str(tmp_path / "meeting.m4a") in cmd
    assert "-f" in cmd
    assert "srt" in cmd


def test_pipeline_error_when_json_missing_after_transcription(tmp_path):
    from service.pipeline import Pipeline
    from service.config_manager import Config

    config = Config(recording_directory=str(tmp_path), output_format="txt")
    errors = []

    # subprocess.run succeeds but writes no JSON file
    with patch("service.pipeline.subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0, stdout="")
        pipeline = Pipeline(
            config=config,
            on_rename_ready=MagicMock(),
            on_error=lambda msg: errors.append(msg),
        )
        audio_file = tmp_path / "recording.wav"
        audio_file.write_bytes(b"fake")
        pipeline.on_recording_complete(audio_file)
        pipeline._queue.wait_all()

    assert len(errors) == 1
    assert "JSON not found" in errors[0]


def test_pipeline_error_on_nonzero_returncode(tmp_path):
    from service.pipeline import Pipeline
    from service.config_manager import Config
    import subprocess as sp

    config = Config(recording_directory=str(tmp_path), output_format="txt")
    errors = []

    with patch("service.pipeline.subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(
            returncode=1,
            stdout="Error: model not found",
        )
        pipeline = Pipeline(
            config=config,
            on_rename_ready=MagicMock(),
            on_error=lambda msg: errors.append(msg),
        )
        audio_file = tmp_path / "bad.wav"
        audio_file.write_bytes(b"fake")
        pipeline.on_recording_complete(audio_file)
        pipeline._queue.wait_all()

    assert len(errors) == 1


def test_pipeline_build_command_uses_sys_executable(tmp_path):
    import sys
    from service.pipeline import Pipeline
    from service.config_manager import Config

    config = Config(recording_directory=str(tmp_path), output_format="json")
    pipeline = Pipeline(config=config, on_rename_ready=MagicMock())
    cmd = pipeline._build_transcribe_command(tmp_path / "audio.wav")
    assert cmd[0] == sys.executable
