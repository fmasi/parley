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
    from service.job_queue import TranscriptionJob

    config = Config(recording_directory=str(tmp_path), output_format="srt")
    pipeline = Pipeline(config=config, on_rename_ready=MagicMock())
    job = TranscriptionJob(
        audio_path=tmp_path / "meeting.m4a",
        output_format="srt",
        on_complete=MagicMock(),
        on_error=MagicMock(),
    )
    cmd = pipeline._build_transcribe_command(job)
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
    from service.job_queue import TranscriptionJob

    config = Config(recording_directory=str(tmp_path), output_format="json")
    pipeline = Pipeline(config=config, on_rename_ready=MagicMock())
    job = TranscriptionJob(
        audio_path=tmp_path / "audio.wav",
        output_format="json",
        on_complete=MagicMock(),
        on_error=MagicMock(),
    )
    cmd = pipeline._build_transcribe_command(job)
    assert cmd[0] == sys.executable


def test_pipeline_build_command_includes_mic_path(tmp_path):
    from service.pipeline import Pipeline
    from service.config_manager import Config
    from service.job_queue import TranscriptionJob

    config = Config(recording_directory=str(tmp_path), output_format="txt")
    pipeline = Pipeline(config=config, on_rename_ready=MagicMock())

    mic_file = tmp_path / "recording_mic.wav"
    mic_file.write_bytes(b"fake mic audio")

    job = TranscriptionJob(
        audio_path=tmp_path / "recording.wav",
        output_format="txt",
        on_complete=MagicMock(),
        on_error=MagicMock(),
        mic_path=mic_file,
    )
    cmd = pipeline._build_transcribe_command(job)
    # Should have two -i flags
    i_indices = [idx for idx, v in enumerate(cmd) if v == "-i"]
    assert len(i_indices) == 2
    assert cmd[i_indices[1] + 1] == str(mic_file)


def test_pipeline_build_command_skips_missing_mic_path(tmp_path):
    from service.pipeline import Pipeline
    from service.config_manager import Config
    from service.job_queue import TranscriptionJob

    config = Config(recording_directory=str(tmp_path), output_format="txt")
    pipeline = Pipeline(config=config, on_rename_ready=MagicMock())

    job = TranscriptionJob(
        audio_path=tmp_path / "recording.wav",
        output_format="txt",
        on_complete=MagicMock(),
        on_error=MagicMock(),
        mic_path=tmp_path / "nonexistent_mic.wav",  # does not exist
    )
    cmd = pipeline._build_transcribe_command(job)
    i_indices = [idx for idx, v in enumerate(cmd) if v == "-i"]
    assert len(i_indices) == 1


def test_pipeline_on_recording_complete_with_mic_path(tmp_path):
    from service.pipeline import Pipeline
    from service.config_manager import Config

    config = Config(recording_directory=str(tmp_path), output_format="txt")
    on_rename = MagicMock()

    with patch("service.pipeline.subprocess.run") as mock_run:
        def fake_transcribe(*args, **kwargs):
            audio_path = Path(args[0][3])
            json_path = audio_path.with_suffix(".json")
            json_path.write_text(json.dumps({"segments": [], "metadata": {}}))
            return MagicMock(returncode=0, stdout="")
        mock_run.side_effect = fake_transcribe

        pipeline = Pipeline(config=config, on_rename_ready=on_rename)
        audio_file = tmp_path / "recording.wav"
        audio_file.write_bytes(b"fake audio")
        mic_file = tmp_path / "recording_mic.wav"
        mic_file.write_bytes(b"fake mic audio")

        pipeline.on_recording_complete(audio_file, mic_path=mic_file)
        pipeline._queue.wait_all()

    # Verify the subprocess command included the mic path
    actual_cmd = mock_run.call_args[0][0]
    i_indices = [idx for idx, v in enumerate(actual_cmd) if v == "-i"]
    assert len(i_indices) == 2
    assert str(mic_file) in actual_cmd


def test_pipeline_passes_hf_token_in_env(tmp_path):
    from service.pipeline import Pipeline
    from service.config_manager import Config

    config = Config(recording_directory=str(tmp_path), output_format="txt", hf_token="hf_abc123")

    with patch("service.pipeline.subprocess.run") as mock_run:
        def fake_transcribe(*args, **kwargs):
            audio_path = Path(args[0][3])
            json_path = audio_path.with_suffix(".json")
            json_path.write_text(json.dumps({"segments": [], "metadata": {}}))
            return MagicMock(returncode=0, stdout="")
        mock_run.side_effect = fake_transcribe

        pipeline = Pipeline(config=config, on_rename_ready=MagicMock())
        audio_file = tmp_path / "test.wav"
        audio_file.write_bytes(b"fake")
        pipeline.on_recording_complete(audio_file)
        pipeline._queue.wait_all()

    env = mock_run.call_args.kwargs.get("env")
    assert env is not None
    assert env["HF_TOKEN"] == "hf_abc123"


def test_pipeline_does_not_override_env_when_no_hf_token(tmp_path):
    from service.pipeline import Pipeline
    from service.config_manager import Config

    config = Config(recording_directory=str(tmp_path), output_format="txt")

    with patch("service.pipeline.subprocess.run") as mock_run:
        def fake_transcribe(*args, **kwargs):
            audio_path = Path(args[0][3])
            json_path = audio_path.with_suffix(".json")
            json_path.write_text(json.dumps({"segments": [], "metadata": {}}))
            return MagicMock(returncode=0, stdout="")
        mock_run.side_effect = fake_transcribe

        pipeline = Pipeline(config=config, on_rename_ready=MagicMock())
        audio_file = tmp_path / "test.wav"
        audio_file.write_bytes(b"fake")
        pipeline.on_recording_complete(audio_file)
        pipeline._queue.wait_all()

    # When hf_token is empty, env should not be overridden
    # so the subprocess inherits the parent environment naturally
    env = mock_run.call_args.kwargs.get("env")
    assert env is None


def test_pipeline_warns_on_no_speakers_without_hf_token(tmp_path):
    from service.pipeline import Pipeline
    from service.config_manager import Config

    config = Config(recording_directory=str(tmp_path), output_format="txt")
    warnings = []

    with patch("service.pipeline.subprocess.run") as mock_run:
        def fake_transcribe(*args, **kwargs):
            audio_path = Path(args[0][3])
            json_path = audio_path.with_suffix(".json")
            json_path.write_text(json.dumps({
                "segments": [{"start": 0, "end": 1, "text": "hello"}],
                "metadata": {}
            }))
            return MagicMock(returncode=0, stdout="")
        mock_run.side_effect = fake_transcribe

        pipeline = Pipeline(
            config=config,
            on_rename_ready=MagicMock(),
            on_warning=lambda msg: warnings.append(msg),
        )
        audio_file = tmp_path / "test.wav"
        audio_file.write_bytes(b"fake")
        pipeline.on_recording_complete(audio_file)
        pipeline._queue.wait_all()

    assert len(warnings) == 1
    assert "HuggingFace token" in warnings[0]


def test_pipeline_no_warning_when_hf_token_set(tmp_path):
    from service.pipeline import Pipeline
    from service.config_manager import Config

    config = Config(recording_directory=str(tmp_path), output_format="txt", hf_token="hf_abc")
    warnings = []

    with patch("service.pipeline.subprocess.run") as mock_run:
        def fake_transcribe(*args, **kwargs):
            audio_path = Path(args[0][3])
            json_path = audio_path.with_suffix(".json")
            json_path.write_text(json.dumps({
                "segments": [{"start": 0, "end": 1, "text": "hello"}],
                "metadata": {}
            }))
            return MagicMock(returncode=0, stdout="")
        mock_run.side_effect = fake_transcribe

        pipeline = Pipeline(
            config=config,
            on_rename_ready=MagicMock(),
            on_warning=lambda msg: warnings.append(msg),
        )
        audio_file = tmp_path / "test.wav"
        audio_file.write_bytes(b"fake")
        pipeline.on_recording_complete(audio_file)
        pipeline._queue.wait_all()

    assert len(warnings) == 0


def test_pipeline_no_warning_when_speakers_detected(tmp_path):
    from service.pipeline import Pipeline
    from service.config_manager import Config

    config = Config(recording_directory=str(tmp_path), output_format="txt")
    warnings = []

    with patch("service.pipeline.subprocess.run") as mock_run:
        def fake_transcribe(*args, **kwargs):
            audio_path = Path(args[0][3])
            json_path = audio_path.with_suffix(".json")
            json_path.write_text(json.dumps({
                "segments": [{"start": 0, "end": 1, "text": "hello", "speaker": "SPEAKER_00"}],
                "metadata": {}
            }))
            return MagicMock(returncode=0, stdout="")
        mock_run.side_effect = fake_transcribe

        pipeline = Pipeline(
            config=config,
            on_rename_ready=MagicMock(),
            on_warning=lambda msg: warnings.append(msg),
        )
        audio_file = tmp_path / "test.wav"
        audio_file.write_bytes(b"fake")
        pipeline.on_recording_complete(audio_file)
        pipeline._queue.wait_all()

    assert len(warnings) == 0
