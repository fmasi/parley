import time
import threading
import pytest
from pathlib import Path


def test_job_runs_and_calls_on_complete(tmp_path):
    from service.job_queue import JobQueue, TranscriptionJob, JobStatus

    results = []

    def worker(job):
        results.append(f"processed:{job.audio_path.name}")

    def on_complete(job):
        results.append("done")

    def on_error(job):
        results.append("error")

    q = JobQueue(worker_fn=worker)
    job = TranscriptionJob(
        audio_path=tmp_path / "test.m4a",
        output_format="txt",
        on_complete=on_complete,
        on_error=on_error,
    )
    q.enqueue(job)
    q.wait_all()
    assert "processed:test.m4a" in results
    assert "done" in results
    assert job.status == JobStatus.COMPLETE


def test_job_failure_calls_on_error(tmp_path):
    from service.job_queue import JobQueue, TranscriptionJob, JobStatus

    errors = []

    def worker(job):
        raise RuntimeError("transcription failed")

    def on_complete(job):
        pass

    def on_error(job):
        errors.append(job.error)

    q = JobQueue(worker_fn=worker)
    job = TranscriptionJob(
        audio_path=tmp_path / "bad.m4a",
        output_format="txt",
        on_complete=on_complete,
        on_error=on_error,
    )
    q.enqueue(job)
    q.wait_all()
    assert "transcription failed" in errors
    assert job.status == JobStatus.FAILED


def test_jobs_run_sequentially(tmp_path):
    from service.job_queue import JobQueue, TranscriptionJob

    order = []
    lock = threading.Lock()

    def worker(job):
        time.sleep(0.05)
        with lock:
            order.append(job.audio_path.name)

    q = JobQueue(worker_fn=worker)
    for i in range(3):
        q.enqueue(TranscriptionJob(
            audio_path=tmp_path / f"rec_{i}.m4a",
            output_format="txt",
            on_complete=lambda j: None,
            on_error=lambda j: None,
        ))
    q.wait_all()
    assert order == ["rec_0.m4a", "rec_1.m4a", "rec_2.m4a"]


def test_pending_count(tmp_path):
    from service.job_queue import JobQueue, TranscriptionJob

    ready = threading.Event()

    def worker(job):
        ready.wait()

    q = JobQueue(worker_fn=worker)
    for i in range(3):
        q.enqueue(TranscriptionJob(
            audio_path=tmp_path / f"r_{i}.m4a",
            output_format="txt",
            on_complete=lambda j: None,
            on_error=lambda j: None,
        ))
    time.sleep(0.05)
    assert q.pending_count >= 2
    ready.set()
    q.wait_all()
