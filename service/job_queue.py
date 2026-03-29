"""Sequential job queue for transcription tasks.

Parallelization upgrade path (future):
  - Replace threading.Thread + Queue with concurrent.futures.ThreadPoolExecutor
  - Add max_workers: int = 1 parameter to JobQueue.__init__
  - Replace self._queue.get() loop with executor.submit(self._worker_fn, job)
  - No other changes needed — TranscriptionJob, on_complete, on_error are unchanged.
"""
import threading
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from queue import Queue, Empty
from typing import Callable, Optional


class JobStatus(Enum):
    PENDING = "pending"
    RUNNING = "running"
    COMPLETE = "complete"
    FAILED = "failed"


@dataclass
class TranscriptionJob:
    audio_path: Path
    output_format: str
    on_complete: Callable[["TranscriptionJob"], None]
    on_error: Callable[["TranscriptionJob"], None]
    mic_path: Optional[Path] = None  # second stream for dual-stream capture
    status: JobStatus = field(default=JobStatus.PENDING, init=False)
    error: Optional[str] = field(default=None, init=False)


class JobQueue:
    """Runs TranscriptionJob instances sequentially in a background thread."""

    def __init__(self, worker_fn: Callable[[TranscriptionJob], None]):
        self._worker_fn = worker_fn
        self._queue: Queue[TranscriptionJob] = Queue()
        self._thread = threading.Thread(target=self._process, daemon=True)
        self._thread.start()

    def enqueue(self, job: TranscriptionJob) -> None:
        self._queue.put(job)

    def wait_all(self, timeout: float = 30.0) -> None:
        """Block until all queued jobs finish. Used in tests."""
        self._queue.join()

    @property
    def pending_count(self) -> int:
        return self._queue.qsize()

    def _process(self) -> None:
        while True:
            job = self._queue.get()
            try:
                job.status = JobStatus.RUNNING
                self._worker_fn(job)
                job.status = JobStatus.COMPLETE
                job.on_complete(job)
            except Exception as exc:
                job.status = JobStatus.FAILED
                job.error = str(exc)
                job.on_error(job)
            finally:
                self._queue.task_done()
