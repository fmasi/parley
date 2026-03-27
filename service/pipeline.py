"""Orchestrates the transcription pipeline: recording complete → transcribe → rename.

Designed for modularity:
- on_recording_complete() is the single entry point. Callers don't know about the queue.
- _run_transcription() is the worker function. Swap in parallel executor later.
- on_rename_ready callback decouples GUI from pipeline logic.
"""
import subprocess
import sys
from pathlib import Path
from typing import Callable, Optional

from service.config_manager import Config
from service.job_queue import JobQueue, TranscriptionJob
from service.logger import get_logger

log = get_logger("pipeline")

TRANSCRIBE_SCRIPT = Path(__file__).parent.parent / "transcribe.py"


class Pipeline:
    """Receives completed recordings and orchestrates transcription."""

    def __init__(
        self,
        config: Config,
        on_rename_ready: Callable[[Path], None],
        on_error: Optional[Callable[[str], None]] = None,
    ):
        self._config = config
        self._on_rename_ready = on_rename_ready
        self._on_error = on_error or (lambda msg: log.error(msg))
        self._queue = JobQueue(worker_fn=self._run_transcription)

    def on_recording_complete(self, audio_path: Path) -> None:
        """Call this when a recording finishes. Enqueues transcription job."""
        log.info(f"Recording complete, queuing transcription: {audio_path.name}")
        job = TranscriptionJob(
            audio_path=audio_path,
            output_format=self._config.output_format,
            on_complete=self._handle_complete,
            on_error=self._handle_error,
        )
        self._queue.enqueue(job)

    def _run_transcription(self, job: TranscriptionJob) -> None:
        """Worker: runs transcribe.py as subprocess."""
        cmd = self._build_transcribe_command(job.audio_path)
        log.info(f"Running: {' '.join(cmd)}")
        subprocess.run(cmd, check=True)

    def _build_transcribe_command(self, audio_path: Path) -> list[str]:
        return [
            sys.executable,
            str(TRANSCRIBE_SCRIPT),
            "-i", str(audio_path),
            "-f", self._config.output_format,
        ]

    def _handle_complete(self, job: TranscriptionJob) -> None:
        json_path = job.audio_path.with_suffix(".json")
        if json_path.exists():
            log.info(f"Transcription complete: {json_path.name}")
            self._on_rename_ready(json_path)
        else:
            self._on_error(f"Transcription finished but JSON not found: {json_path}")

    def _handle_error(self, job: TranscriptionJob) -> None:
        msg = f"Transcription failed for {job.audio_path.name}: {job.error}"
        log.error(msg)
        self._on_error(msg)
