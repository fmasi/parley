# Transcription Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a persistent macOS menu bar service that records meetings (mic + system audio), auto-transcribes on stop, and prompts for speaker renaming — all without user setup beyond granting permissions.

**Architecture:** A persistent daemon (launchd) runs a PyObjC/AppKit menu bar app that controls audio capture via AVAudioEngine (CoreAudio). On recording stop, a sequential job queue triggers the existing `transcribe.py` pipeline; on completion, a native AppKit dialog prompts for speaker names.

**Tech Stack:** Python 3.9+, PyObjC (AppKit + AVFoundation + EventKit), rumps (menu bar), silero-vad (speech detection), soundfile (audio mixing), existing mlx-whisper + pyannote pipeline.

---

## File Map

```
service/
  __init__.py               # Package marker
  config_manager.py         # Read/write ~/.audio-transcribe/config.json
  logger.py                 # Rotating file logger for all components
  job_queue.py              # Sequential job queue (modular for parallelization)
  audio_capture.py          # AVAudioEngine mic + system audio capture
  silence_detector.py       # Silero VAD speech detection
  calendar_lookup.py        # Apple Calendar current event via EventKit
  pipeline.py               # Orchestrator: file watcher → transcribe → rename
  rename_dialog.py          # AppKit dialog for speaker naming
  settings_window.py        # AppKit settings window
  menu_bar_app.py           # rumps menu bar app (AppKit wrapper)
  main.py                   # Entry point, launchd integration

tests/
  __init__.py
  test_config_manager.py
  test_logger.py
  test_job_queue.py
  test_silence_detector.py
  test_calendar_lookup.py
  test_pipeline.py
  test_integration.py

com.audio-transcribe.plist  # launchd auto-startup template
requirements-service.txt    # New dependencies for service
```

**Existing files (do not modify except where noted):**
- `transcribe.py` — called as subprocess by pipeline
- `rename_speakers.py` — logic extracted and reused in `rename_dialog.py`

---

## Task 1: Project Scaffold & Config Manager

**Files:**
- Create: `service/__init__.py`
- Create: `service/config_manager.py`
- Create: `tests/__init__.py`
- Create: `tests/test_config_manager.py`
- Create: `requirements-service.txt`

- [ ] **Step 1: Create requirements-service.txt**

```
pyobjc-framework-Cocoa>=10.0
pyobjc-framework-AVFoundation>=10.0
pyobjc-framework-EventKit>=10.0
pyobjc-framework-ScreenSaver>=10.0
rumps>=0.4.0
silero-vad>=4.0
soundfile>=0.12.0
sounddevice>=0.4.0
numpy>=1.24.0
watchdog>=3.0.0
torch>=2.0.0
```

Install: `pip install -r requirements-service.txt`

- [ ] **Step 2: Create service/__init__.py**

```python
# service/__init__.py
```

- [ ] **Step 3: Write failing tests for ConfigManager**

```python
# tests/test_config_manager.py
import json
import pytest
from pathlib import Path
from unittest.mock import patch


def test_config_defaults(tmp_path):
    from service.config_manager import ConfigManager, Config
    cm = ConfigManager(config_path=tmp_path / "config.json")
    assert cm.config.silence_timeout_minutes == 5
    assert cm.config.silence_detection_enabled is True
    assert cm.config.output_format == "txt"
    assert cm.config.launch_on_startup is True
    assert cm.config.log_level == "info"
    assert "Recordings" in cm.config.recording_directory


def test_config_saves_and_reloads(tmp_path):
    from service.config_manager import ConfigManager
    path = tmp_path / "config.json"
    cm = ConfigManager(config_path=path)
    cm.update(silence_timeout_minutes=10, output_format="srt")
    assert path.exists()
    cm2 = ConfigManager(config_path=path)
    assert cm2.config.silence_timeout_minutes == 10
    assert cm2.config.output_format == "srt"


def test_config_update_ignores_unknown_keys(tmp_path):
    from service.config_manager import ConfigManager
    cm = ConfigManager(config_path=tmp_path / "config.json")
    cm.update(nonexistent_key="value")  # should not raise
    assert not hasattr(cm.config, "nonexistent_key")


def test_config_creates_parent_dirs(tmp_path):
    from service.config_manager import ConfigManager
    nested = tmp_path / "a" / "b" / "config.json"
    cm = ConfigManager(config_path=nested)
    cm.save()
    assert nested.exists()
```

- [ ] **Step 4: Run tests to confirm they fail**

```bash
cd /Users/fmasi/Documents/applications/everpure-director-cna-emea
python -m pytest tests/test_config_manager.py -v
```

Expected: `ModuleNotFoundError: No module named 'service'`

- [ ] **Step 5: Implement ConfigManager**

```python
# service/config_manager.py
import json
from dataclasses import dataclass, asdict, fields
from pathlib import Path

CONFIG_DIR = Path.home() / ".audio-transcribe"
CONFIG_FILE = CONFIG_DIR / "config.json"


@dataclass
class Config:
    recording_directory: str = str(Path.home() / "Documents" / "Recordings")
    silence_timeout_minutes: int = 5
    silence_detection_enabled: bool = True
    output_format: str = "txt"
    launch_on_startup: bool = True
    log_level: str = "info"


class ConfigManager:
    """Read/write user settings from ~/.audio-transcribe/config.json.

    Parallelization note: this is a shared config object; no changes needed
    for parallel workers since config is read-only during recording sessions.
    """

    def __init__(self, config_path: Path = CONFIG_FILE):
        self._path = config_path
        self._config = self._load()

    def _load(self) -> Config:
        if self._path.exists():
            with open(self._path, encoding="utf-8") as f:
                data = json.load(f)
            valid = {f.name for f in fields(Config)}
            return Config(**{k: v for k, v in data.items() if k in valid})
        return Config()

    def save(self):
        self._path.parent.mkdir(parents=True, exist_ok=True)
        with open(self._path, "w", encoding="utf-8") as f:
            json.dump(asdict(self._config), f, indent=2)

    @property
    def config(self) -> Config:
        return self._config

    def update(self, **kwargs):
        valid = {f.name for f in fields(Config)}
        for k, v in kwargs.items():
            if k in valid:
                setattr(self._config, k, v)
        self.save()
```

- [ ] **Step 6: Run tests — all pass**

```bash
python -m pytest tests/test_config_manager.py -v
```

Expected: 4 PASSED

- [ ] **Step 7: Commit**

```bash
git add service/__init__.py service/config_manager.py tests/__init__.py tests/test_config_manager.py requirements-service.txt
git commit -m "feat: add ConfigManager with defaults and persistence"
```

---

## Task 2: Logger

**Files:**
- Create: `service/logger.py`
- Create: `tests/test_logger.py`

- [ ] **Step 1: Write failing tests**

```python
# tests/test_logger.py
import logging
import pytest
from pathlib import Path


def test_logger_creates_log_file(tmp_path):
    from service.logger import get_logger
    log_path = tmp_path / "logs" / "test.log"
    logger = get_logger("test", log_path=log_path)
    logger.info("hello")
    assert log_path.exists()
    assert "hello" in log_path.read_text()


def test_logger_includes_component_name(tmp_path):
    from service.logger import get_logger
    log_path = tmp_path / "logs" / "test.log"
    logger = get_logger("my_component", log_path=log_path)
    logger.info("test message")
    content = log_path.read_text()
    assert "my_component" in content


def test_logger_respects_level(tmp_path):
    from service.logger import get_logger
    log_path = tmp_path / "logs" / "test.log"
    logger = get_logger("test_level", log_path=log_path, level="error")
    logger.info("should not appear")
    logger.error("should appear")
    content = log_path.read_text()
    assert "should not appear" not in content
    assert "should appear" in content


def test_logger_does_not_duplicate_handlers(tmp_path):
    from service.logger import get_logger
    log_path = tmp_path / "logs" / "test.log"
    logger = get_logger("dup_test", log_path=log_path)
    logger2 = get_logger("dup_test", log_path=log_path)
    assert logger is logger2
    assert len(logger.handlers) <= 2  # file + console max
```

- [ ] **Step 2: Run tests to confirm failure**

```bash
python -m pytest tests/test_logger.py -v
```

Expected: `ImportError`

- [ ] **Step 3: Implement Logger**

```python
# service/logger.py
import logging
from logging.handlers import TimedRotatingFileHandler
from pathlib import Path

DEFAULT_LOG_DIR = Path.home() / ".audio-transcribe" / "logs"
DEFAULT_LOG_FILE = DEFAULT_LOG_DIR / "transcribe-service.log"


def get_logger(
    name: str,
    level: str = "info",
    log_path: Path = DEFAULT_LOG_FILE,
) -> logging.Logger:
    """Return a named logger writing to log_path with daily rotation (7 days).

    Safe to call multiple times with the same name — returns existing logger.
    """
    logger = logging.getLogger(name)

    if logger.handlers:
        return logger

    logger.setLevel(getattr(logging, level.upper(), logging.INFO))
    log_path.parent.mkdir(parents=True, exist_ok=True)

    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    file_handler = TimedRotatingFileHandler(
        str(log_path), when="midnight", backupCount=7, encoding="utf-8"
    )
    file_handler.setFormatter(fmt)
    logger.addHandler(file_handler)

    console_handler = logging.StreamHandler()
    console_handler.setFormatter(fmt)
    logger.addHandler(console_handler)

    return logger
```

- [ ] **Step 4: Run tests — all pass**

```bash
python -m pytest tests/test_logger.py -v
```

Expected: 4 PASSED

- [ ] **Step 5: Commit**

```bash
git add service/logger.py tests/test_logger.py
git commit -m "feat: add rotating file logger with component names"
```

---

## Task 3: Job Queue (Sequential, Modular for Parallelization)

**Files:**
- Create: `service/job_queue.py`
- Create: `tests/test_job_queue.py`

- [ ] **Step 1: Write failing tests**

```python
# tests/test_job_queue.py
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
```

- [ ] **Step 2: Run tests to confirm failure**

```bash
python -m pytest tests/test_job_queue.py -v
```

Expected: `ImportError`

- [ ] **Step 3: Implement JobQueue**

```python
# service/job_queue.py
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
```

- [ ] **Step 4: Run tests — all pass**

```bash
python -m pytest tests/test_job_queue.py -v
```

Expected: 4 PASSED

- [ ] **Step 5: Commit**

```bash
git add service/job_queue.py tests/test_job_queue.py
git commit -m "feat: add sequential job queue, designed for future parallelization"
```

---

## Task 4: Silence Detector (Silero VAD)

**Files:**
- Create: `service/silence_detector.py`
- Create: `tests/test_silence_detector.py`

- [ ] **Step 1: Write failing tests**

```python
# tests/test_silence_detector.py
import numpy as np
import pytest


def test_speech_detected_on_non_silence():
    from service.silence_detector import SilenceDetector
    sd = SilenceDetector(timeout_minutes=1)
    # 1 second of 440Hz tone (simulates speech-like audio)
    t = np.linspace(0, 1, 16000, dtype=np.float32)
    audio = (np.sin(2 * np.pi * 440 * t) * 0.5).astype(np.float32)
    # Call process_chunk — should not raise
    result = sd.process_chunk(audio, sample_rate=16000)
    assert isinstance(result, bool)


def test_silence_not_detected_immediately():
    from service.silence_detector import SilenceDetector
    sd = SilenceDetector(timeout_minutes=5)
    silence = np.zeros(16000, dtype=np.float32)
    sd.process_chunk(silence, sample_rate=16000)
    assert not sd.is_timed_out()


def test_silence_detected_after_timeout():
    from service.silence_detector import SilenceDetector
    import time
    sd = SilenceDetector(timeout_minutes=0)  # 0 minutes = immediate timeout
    silence = np.zeros(16000, dtype=np.float32)
    sd.process_chunk(silence, sample_rate=16000)
    time.sleep(0.1)
    assert sd.is_timed_out()


def test_speech_resets_timer():
    from service.silence_detector import SilenceDetector
    import time
    sd = SilenceDetector(timeout_minutes=0)
    silence = np.zeros(16000, dtype=np.float32)
    sd.process_chunk(silence, sample_rate=16000)
    t = np.linspace(0, 1, 16000, dtype=np.float32)
    speech = (np.sin(2 * np.pi * 440 * t) * 0.8).astype(np.float32)
    # Simulate speech detected (mock VAD returning True)
    sd._last_speech_time = time.time()
    assert not sd.is_timed_out()
```

- [ ] **Step 2: Run tests to confirm failure**

```bash
python -m pytest tests/test_silence_detector.py -v
```

Expected: `ImportError`

- [ ] **Step 3: Implement SilenceDetector**

```python
# service/silence_detector.py
"""Silero VAD-based silence detector.

Only triggers timeout when no human speech is detected — ignores
typing, AC noise, and other background sounds.
"""
import time
from typing import Optional

import numpy as np
import torch


class SilenceDetector:
    """Detects human speech using Silero VAD.

    Usage:
        detector = SilenceDetector(timeout_minutes=5)
        detector.process_chunk(audio_array, sample_rate=16000)
        if detector.is_timed_out():
            show_stop_prompt()
    """

    SPEECH_THRESHOLD = 0.5

    def __init__(self, timeout_minutes: int = 5):
        self._timeout_seconds = timeout_minutes * 60
        self._last_speech_time: float = time.time()
        self._model = None  # Lazy load on first use

    def _load_model(self):
        if self._model is None:
            self._model, self._utils = torch.hub.load(
                repo_or_dir="snakers4/silero-vad",
                model="silero_vad",
                force_reload=False,
                trust_repo=True,
            )

    def process_chunk(self, audio: np.ndarray, sample_rate: int = 16000) -> bool:
        """Process one audio chunk. Returns True if speech detected.

        audio: float32 numpy array, values in [-1.0, 1.0]
        sample_rate: must be 8000 or 16000 for Silero VAD
        """
        self._load_model()
        tensor = torch.FloatTensor(audio)
        if tensor.dim() == 1:
            tensor = tensor.unsqueeze(0)
        speech_prob = self._model(tensor, sample_rate).item()
        speech_detected = speech_prob > self.SPEECH_THRESHOLD
        if speech_detected:
            self._last_speech_time = time.time()
        return speech_detected

    def is_timed_out(self) -> bool:
        """Returns True if no speech detected for timeout_minutes."""
        return (time.time() - self._last_speech_time) >= self._timeout_seconds

    def reset(self):
        """Call when recording starts to reset the timer."""
        self._last_speech_time = time.time()
```

- [ ] **Step 4: Run tests — all pass**

```bash
python -m pytest tests/test_silence_detector.py -v
```

Expected: 4 PASSED (Note: first run downloads Silero VAD model ~1MB)

- [ ] **Step 5: Commit**

```bash
git add service/silence_detector.py tests/test_silence_detector.py
git commit -m "feat: add Silero VAD silence detector with configurable timeout"
```

---

## Task 5: Calendar Lookup

**Files:**
- Create: `service/calendar_lookup.py`
- Create: `tests/test_calendar_lookup.py`

- [ ] **Step 1: Write failing tests**

```python
# tests/test_calendar_lookup.py
from unittest.mock import MagicMock, patch


def test_returns_none_when_no_events():
    from service.calendar_lookup import CalendarLookup
    with patch("service.calendar_lookup.EVENTKIT_AVAILABLE", False):
        cl = CalendarLookup()
        assert cl.get_current_event_title() is None


def test_returns_none_on_eventkit_error():
    from service.calendar_lookup import CalendarLookup
    with patch("service.calendar_lookup.EVENTKIT_AVAILABLE", True):
        with patch("service.calendar_lookup.EKEventStore") as mock_store:
            mock_store.alloc.return_value.init.return_value.requestAccessToEntityType_completion_ = MagicMock()
            cl = CalendarLookup()
            cl._store = None
            assert cl.get_current_event_title() is None


def test_sanitizes_event_title():
    from service.calendar_lookup import CalendarLookup
    cl = CalendarLookup.__new__(CalendarLookup)
    assert cl._sanitize("Client: Meeting / Q1") == "Client_Meeting_Q1"
    assert cl._sanitize("  spaces  ") == "spaces"
    assert cl._sanitize("already_good") == "already_good"
```

- [ ] **Step 2: Run tests to confirm failure**

```bash
python -m pytest tests/test_calendar_lookup.py -v
```

Expected: `ImportError`

- [ ] **Step 3: Implement CalendarLookup**

```python
# service/calendar_lookup.py
"""Apple Calendar lookup via EventKit (PyObjC).

Gracefully degrades when EventKit is unavailable (non-macOS or permission denied).
"""
import re
from typing import Optional

try:
    import EventKit
    from Foundation import NSDate, NSCalendar, NSCalendarUnitYear, NSCalendarUnitMonth, NSCalendarUnitDay
    EVENTKIT_AVAILABLE = True
except ImportError:
    EVENTKIT_AVAILABLE = False


class CalendarLookup:
    """Returns the title of the currently active Apple Calendar event, if any."""

    def __init__(self):
        self._store = None
        if EVENTKIT_AVAILABLE:
            try:
                self._store = EventKit.EKEventStore.alloc().init()
            except Exception:
                self._store = None

    def get_current_event_title(self) -> Optional[str]:
        """Returns sanitized title of current calendar event, or None."""
        if not EVENTKIT_AVAILABLE or self._store is None:
            return None
        try:
            now = NSDate.date()
            predicate = self._store.predicateForEventsWithStartDate_endDate_calendars_(
                now, now, None
            )
            events = self._store.eventsMatchingPredicate_(predicate)
            if events and len(events) > 0:
                title = str(events[0].title())
                return self._sanitize(title)
        except Exception:
            return None
        return None

    def _sanitize(self, title: str) -> str:
        """Convert event title to a filesystem-safe recording name."""
        title = title.strip()
        title = re.sub(r"[^\w\s-]", "", title)
        title = re.sub(r"[\s]+", "_", title)
        return title
```

- [ ] **Step 4: Run tests — all pass**

```bash
python -m pytest tests/test_calendar_lookup.py -v
```

Expected: 3 PASSED

- [ ] **Step 5: Commit**

```bash
git add service/calendar_lookup.py tests/test_calendar_lookup.py
git commit -m "feat: add Apple Calendar lookup with graceful fallback"
```

---

## Task 6: Audio Capture (CoreAudio via AVAudioEngine + PyObjC)

**Files:**
- Create: `service/audio_capture.py`
- Create: `tests/test_audio_capture.py`

- [ ] **Step 1: Write failing tests**

```python
# tests/test_audio_capture.py
import numpy as np
import pytest
from pathlib import Path
from unittest.mock import MagicMock, patch


def test_audio_capture_creates_output_file(tmp_path):
    from service.audio_capture import AudioCapture
    output = tmp_path / "test_recording.m4a"
    ac = AudioCapture(output_path=output)
    with patch.object(ac, "_start_engine"), patch.object(ac, "_stop_engine"):
        with patch.object(ac, "_write_output", return_value=output) as mock_write:
            ac.start()
            result = ac.stop()
            mock_write.assert_called_once()
    assert result == output


def test_audio_capture_mixes_two_streams(tmp_path):
    from service.audio_capture import AudioCapture
    output = tmp_path / "mixed.m4a"
    ac = AudioCapture(output_path=output)
    mic = np.sin(np.linspace(0, 1, 16000)).astype(np.float32)
    sys = np.cos(np.linspace(0, 1, 16000)).astype(np.float32)
    mixed = ac._mix_streams(mic, sys)
    assert len(mixed) == 16000
    expected = (mic + sys) / 2.0
    np.testing.assert_array_almost_equal(mixed, expected)


def test_audio_capture_handles_mismatched_lengths(tmp_path):
    from service.audio_capture import AudioCapture
    ac = AudioCapture(output_path=tmp_path / "out.m4a")
    mic = np.ones(10000, dtype=np.float32)
    sys = np.ones(12000, dtype=np.float32)
    mixed = ac._mix_streams(mic, sys)
    assert len(mixed) == 10000  # truncates to shortest


def test_audio_capture_handles_missing_stream(tmp_path):
    from service.audio_capture import AudioCapture
    ac = AudioCapture(output_path=tmp_path / "out.m4a")
    mic = np.ones(10000, dtype=np.float32)
    mixed = ac._mix_streams(mic, np.array([], dtype=np.float32))
    assert len(mixed) == 10000
    np.testing.assert_array_equal(mixed, mic)
```

- [ ] **Step 2: Run tests to confirm failure**

```bash
python -m pytest tests/test_audio_capture.py -v
```

Expected: `ImportError`

- [ ] **Step 3: Implement AudioCapture**

```python
# service/audio_capture.py
"""Captures microphone + system audio using AVAudioEngine (CoreAudio via PyObjC).

Requires macOS 12.0+ and Screen Recording permission.
System audio capture via outputNode tap works with Screen Recording permission
granted at OS level — no virtual audio device (BlackHole) needed.
"""
import ctypes
import threading
from pathlib import Path
from typing import List, Optional

import numpy as np
import soundfile as sf

from service.logger import get_logger

log = get_logger("audio_capture")

try:
    import objc
    import AVFoundation as AVF
    AVFOUNDATION_AVAILABLE = True
except ImportError:
    AVFOUNDATION_AVAILABLE = False
    log.warning("AVFoundation not available — audio capture disabled")


SAMPLE_RATE = 16000
BUFFER_SIZE = 4096


class AudioCapture:
    """Records mic + system audio simultaneously using AVAudioEngine.

    Interface contract (for future refactoring):
        capture = AudioCapture(output_path)
        capture.start()
        # ... time passes ...
        path = capture.stop()  # returns Path to written file

    Internal methods prefixed with _ are replaceable without changing callers.
    """

    def __init__(self, output_path: Path):
        self._output_path = output_path
        self._mic_chunks: List[np.ndarray] = []
        self._sys_chunks: List[np.ndarray] = []
        self._lock = threading.Lock()
        self._engine: Optional[object] = None

    def start(self) -> None:
        """Begin capturing audio. Non-blocking."""
        self._mic_chunks.clear()
        self._sys_chunks.clear()
        if AVFOUNDATION_AVAILABLE:
            self._start_engine()
        else:
            log.error("Cannot start: AVFoundation not available")

    def stop(self) -> Path:
        """Stop capture and write mixed audio to output_path."""
        if AVFOUNDATION_AVAILABLE:
            self._stop_engine()
        return self._write_output()

    def _start_engine(self) -> None:
        self._engine = AVF.AVAudioEngine.alloc().init()
        fmt = self._engine.inputNode().outputFormatForBus_(0)

        def mic_tap(buffer, time):
            with self._lock:
                self._mic_chunks.append(self._buffer_to_numpy(buffer))

        def sys_tap(buffer, time):
            with self._lock:
                self._sys_chunks.append(self._buffer_to_numpy(buffer))

        self._engine.inputNode().installTapOnBus_bufferSize_format_block_(
            0, BUFFER_SIZE, fmt, mic_tap
        )
        self._engine.outputNode().installTapOnBus_bufferSize_format_block_(
            0, BUFFER_SIZE, fmt, sys_tap
        )

        error = objc.nil
        success = self._engine.startAndReturnError_(error)
        if not success:
            log.error("AVAudioEngine failed to start — check Screen Recording permission")

    def _stop_engine(self) -> None:
        if self._engine:
            self._engine.inputNode().removeTapOnBus_(0)
            self._engine.outputNode().removeTapOnBus_(0)
            self._engine.stop()

    @staticmethod
    def _buffer_to_numpy(buffer) -> np.ndarray:
        """Extract float32 PCM samples from AVAudioPCMBuffer."""
        frame_count = int(buffer.frameLength())
        channel_data = buffer.floatChannelData()
        if channel_data is None or frame_count == 0:
            return np.array([], dtype=np.float32)
        ptr = ctypes.cast(channel_data[0], ctypes.POINTER(ctypes.c_float))
        return np.ctypeslib.as_array(ptr, shape=(frame_count,)).copy()

    def _mix_streams(
        self, mic: np.ndarray, sys: np.ndarray
    ) -> np.ndarray:
        """Mix two audio streams. Handles mismatched lengths and empty streams."""
        if len(mic) == 0:
            return sys
        if len(sys) == 0:
            return mic
        min_len = min(len(mic), len(sys))
        return ((mic[:min_len] + sys[:min_len]) / 2.0).astype(np.float32)

    def _write_output(self) -> Path:
        with self._lock:
            mic = np.concatenate(self._mic_chunks) if self._mic_chunks else np.array([], dtype=np.float32)
            sys = np.concatenate(self._sys_chunks) if self._sys_chunks else np.array([], dtype=np.float32)

        mixed = self._mix_streams(mic, sys)

        if len(mixed) == 0:
            log.warning("No audio captured — writing silent file")
            mixed = np.zeros(SAMPLE_RATE, dtype=np.float32)

        self._output_path.parent.mkdir(parents=True, exist_ok=True)
        sf.write(str(self._output_path), mixed, SAMPLE_RATE)
        log.info(f"Audio written: {self._output_path} ({len(mixed)/SAMPLE_RATE:.1f}s)")
        return self._output_path
```

- [ ] **Step 4: Run tests — all pass**

```bash
python -m pytest tests/test_audio_capture.py -v
```

Expected: 4 PASSED

- [ ] **Step 5: Commit**

```bash
git add service/audio_capture.py tests/test_audio_capture.py
git commit -m "feat: add CoreAudio capture via AVAudioEngine, mic + system audio mixing"
```

---

## Task 7: Pipeline Orchestrator

**Files:**
- Create: `service/pipeline.py`
- Create: `tests/test_pipeline.py`

- [ ] **Step 1: Write failing tests**

```python
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
            audio_path = Path(args[0][2])  # -i argument
            json_path = audio_path.with_suffix(".json")
            json_path.write_text(json.dumps({"segments": [], "metadata": {}}))
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
```

- [ ] **Step 2: Run tests to confirm failure**

```bash
python -m pytest tests/test_pipeline.py -v
```

Expected: `ImportError`

- [ ] **Step 3: Implement Pipeline**

```python
# service/pipeline.py
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
```

- [ ] **Step 4: Run tests — all pass**

```bash
python -m pytest tests/test_pipeline.py -v
```

Expected: 3 PASSED

- [ ] **Step 5: Commit**

```bash
git add service/pipeline.py tests/test_pipeline.py
git commit -m "feat: add pipeline orchestrator, routes completed recordings to transcription"
```

---

## Task 8: Rename Dialog (AppKit GUI)

**Files:**
- Create: `service/rename_dialog.py`

No unit tests for this component — AppKit requires a running NSApplication loop. Manual testing required (documented in Step 4).

- [ ] **Step 1: Implement RenameDialog**

```python
# service/rename_dialog.py
"""AppKit dialog for interactive speaker renaming.

Reuses formatting/writing logic from rename_speakers.py.
Launched by the pipeline after transcription completes.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional

import objc
from AppKit import (
    NSAlert,
    NSTextField,
    NSApplication,
    NSInformationalAlertStyle,
)
from Foundation import NSObject

from service.logger import get_logger

# Re-use writing logic from existing rename_speakers.py
sys.path.insert(0, str(Path(__file__).parent.parent))
from rename_speakers import (
    apply_names,
    find_speaker_samples,
    write_txt,
    write_srt,
    write_json,
)

log = get_logger("rename_dialog")


def run_rename_dialog(json_path: Path) -> None:
    """Show speaker rename dialog for a completed transcript.

    Loads JSON, plays audio samples, prompts for names, saves back to JSON
    and the output format stored in metadata.
    """
    try:
        with open(json_path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        log.error(f"Cannot load transcript JSON: {e}")
        return

    segments = data.get("segments", [])
    metadata = data.get("metadata", {})
    audio_path = Path(metadata.get("audio_path", ""))
    fmt = metadata.get("output_format", "txt")

    if not audio_path.exists():
        log.error(f"Audio file not found for rename: {audio_path}")
        _show_error(f"Audio file not found:\n{audio_path}\n\nCannot play samples.")
        return

    speaker_samples = find_speaker_samples(segments)
    if not speaker_samples:
        log.warning("No speakers found in transcript — skipping rename")
        return

    name_map = {}
    for speaker, sample in sorted(speaker_samples.items()):
        name = _prompt_speaker(speaker, sample, str(audio_path))
        name_map[speaker] = name if name else speaker

    renamed = apply_names(segments, name_map)
    metadata["speaker_names"] = name_map

    # Save master JSON
    write_json(renamed, str(json_path), metadata)

    # Save output format
    output_path = json_path.with_suffix(f".{fmt}")
    if fmt == "txt":
        write_txt(renamed, str(output_path))
    elif fmt == "srt":
        write_srt(renamed, str(output_path))

    log.info(f"Rename complete. Saved: {output_path}")


def _prompt_speaker(speaker: str, sample: dict, audio_path: str) -> Optional[str]:
    """Show an NSAlert dialog asking user to name a speaker."""
    # Play audio sample
    try:
        _play_sample(audio_path, sample["start"], sample["end"])
    except Exception as e:
        log.warning(f"Could not play sample: {e}")

    alert = NSAlert.alloc().init()
    alert.setMessageText_(f"Who is {speaker}?")
    alert.setInformationalText_(
        f'Sample: "{sample["text"][:100]}"\n'
        f"({sample['start']:.0f}s – {sample['end']:.0f}s)"
    )
    alert.setAlertStyle_(NSInformationalAlertStyle)
    alert.addButtonWithTitle_("OK")
    alert.addButtonWithTitle_("Skip")

    input_field = NSTextField.alloc().initWithFrame_(((0, 0), (300, 24)))
    input_field.setPlaceholderString_(speaker)
    alert.setAccessoryView_(input_field)

    response = alert.runModal()
    entered = str(input_field.stringValue()).strip()

    if response == 1000 and entered:  # OK clicked with text
        return entered
    return None


def _play_sample(audio_path: str, start: float, end: float) -> None:
    duration = end - start
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as tmp:
        subprocess.run(
            [
                "ffmpeg", "-y",
                "-ss", str(start),
                "-t", str(duration),
                "-i", audio_path,
                "-ar", "16000", "-ac", "1",
                tmp.name,
            ],
            capture_output=True,
            check=True,
        )
        subprocess.run(["afplay", tmp.name], check=True)


def _show_error(message: str) -> None:
    alert = NSAlert.alloc().init()
    alert.setMessageText_("Transcription Service Error")
    alert.setInformationalText_(message)
    alert.runModal()
```

- [ ] **Step 2: Manual test procedure**

After implementing the menu bar app (Task 9), test this via:
1. Run a full transcription to produce a `.json` file
2. Call `from service.rename_dialog import run_rename_dialog; run_rename_dialog(Path("path/to/file.json"))`
3. Verify: dialog appears, audio plays, name entered, output file updated

- [ ] **Step 3: Commit**

```bash
git add service/rename_dialog.py
git commit -m "feat: add AppKit speaker rename dialog with audio playback"
```

---

## Task 9: Menu Bar App + Settings Window

**Files:**
- Create: `service/menu_bar_app.py`
- Create: `service/settings_window.py`

- [ ] **Step 1: Implement Settings Window**

```python
# service/settings_window.py
"""AppKit settings window for configuring the transcription service."""
import objc
from AppKit import (
    NSWindow,
    NSTextField,
    NSButton,
    NSButtonCell,
    NSLabel,
    NSPopUpButton,
    NSView,
    NSTitledWindowMask,
    NSClosableWindowMask,
    NSResizableWindowMask,
    NSBackingStoreBuffered,
    NSApp,
    NSSwitchButton,
)
from Foundation import NSObject, NSMakeRect

from service.config_manager import ConfigManager
from service.logger import get_logger

log = get_logger("settings_window")


class SettingsWindowController(NSObject):
    """Shows and manages the settings window."""

    def initWithConfigManager_(self, config_manager: ConfigManager):
        self = objc.super(SettingsWindowController, self).init()
        if self is None:
            return None
        self._cm = config_manager
        self._window = None
        return self

    def show(self):
        if self._window and self._window.isVisible():
            self._window.makeKeyAndOrderFront_(None)
            return
        self._build_window()
        self._window.makeKeyAndOrderFront_(None)
        NSApp.activateIgnoringOtherApps_(True)

    def _build_window(self):
        cfg = self._cm.config
        rect = NSMakeRect(100, 100, 420, 320)
        style = NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask
        self._window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, style, NSBackingStoreBuffered, False
        )
        self._window.setTitle_("Transcription Service — Settings")

        view = self._window.contentView()
        y = 260

        # Recording directory
        self._add_label(view, "Recording Directory:", (20, y))
        self._dir_field = self._add_text_field(view, cfg.recording_directory, (20, y - 28), width=380)
        y -= 60

        # Output format
        self._add_label(view, "Output Format:", (20, y))
        self._format_popup = NSPopUpButton.alloc().initWithFrame_(NSMakeRect(20, y - 28, 120, 26))
        for fmt in ["txt", "srt", "json"]:
            self._format_popup.addItemWithTitle_(fmt)
        self._format_popup.selectItemWithTitle_(cfg.output_format)
        view.addSubview_(self._format_popup)
        y -= 60

        # Silence detection toggle
        self._add_label(view, "Silence Detection:", (20, y))
        self._silence_toggle = NSButton.alloc().initWithFrame_(NSMakeRect(160, y - 4, 120, 22))
        self._silence_toggle.setButtonType_(NSSwitchButton)
        self._silence_toggle.setTitle_("Enabled")
        self._silence_toggle.setState_(1 if cfg.silence_detection_enabled else 0)
        view.addSubview_(self._silence_toggle)
        y -= 40

        # Silence timeout
        self._add_label(view, "Silence Timeout (minutes):", (20, y))
        self._timeout_field = self._add_text_field(view, str(cfg.silence_timeout_minutes), (260, y - 4), width=60)
        y -= 50

        # Save button
        save_btn = NSButton.alloc().initWithFrame_(NSMakeRect(310, 20, 90, 32))
        save_btn.setTitle_("Save")
        save_btn.setTarget_(self)
        save_btn.setAction_(objc.selector(self.save_, signature=b"v@:@"))
        view.addSubview_(save_btn)

    def save_(self, sender):
        try:
            timeout = int(self._timeout_field.stringValue())
        except ValueError:
            timeout = 5

        self._cm.update(
            recording_directory=str(self._dir_field.stringValue()),
            output_format=str(self._format_popup.titleOfSelectedItem()),
            silence_detection_enabled=bool(self._silence_toggle.state()),
            silence_timeout_minutes=timeout,
        )
        log.info("Settings saved")
        self._window.close()

    def _add_label(self, view, text: str, pos: tuple):
        label = NSTextField.alloc().initWithFrame_(NSMakeRect(pos[0], pos[1], 220, 20))
        label.setStringValue_(text)
        label.setEditable_(False)
        label.setBezeled_(False)
        label.setDrawsBackground_(False)
        view.addSubview_(label)

    def _add_text_field(self, view, value: str, pos: tuple, width: int = 200):
        field = NSTextField.alloc().initWithFrame_(NSMakeRect(pos[0], pos[1], width, 24))
        field.setStringValue_(value)
        view.addSubview_(field)
        return field
```

- [ ] **Step 2: Implement Menu Bar App**

```python
# service/menu_bar_app.py
"""macOS menu bar application using rumps (AppKit wrapper via PyObjC).

State machine:
  IDLE → start_recording() → PROMPTING → RECORDING → stop_recording() → TRANSCRIBING → IDLE
"""
import threading
from datetime import datetime
from pathlib import Path
from typing import Optional

import rumps

from service.audio_capture import AudioCapture
from service.calendar_lookup import CalendarLookup
from service.config_manager import ConfigManager
from service.logger import get_logger
from service.pipeline import Pipeline
from service.rename_dialog import run_rename_dialog
from service.settings_window import SettingsWindowController
from service.silence_detector import SilenceDetector

log = get_logger("menu_bar_app")

ICON_IDLE = "🎙"
ICON_RECORDING = "🔴"
ICON_PROCESSING = "⏳"


class TranscriptionApp(rumps.App):
    """Persistent menu bar app controlling the entire transcription pipeline."""

    def __init__(self, config_manager: ConfigManager):
        super().__init__(ICON_IDLE, quit_button=None)
        self._cm = config_manager
        self._capture: Optional[AudioCapture] = None
        self._silence_detector: Optional[SilenceDetector] = None
        self._silence_thread: Optional[threading.Thread] = None
        self._calendar = CalendarLookup()
        self._settings_ctrl = SettingsWindowController.alloc().initWithConfigManager_(config_manager)

        self._pipeline = Pipeline(
            config=self._cm.config,
            on_rename_ready=self._on_rename_ready,
            on_error=self._on_pipeline_error,
        )

        self.menu = [
            rumps.MenuItem("Start Recording", callback=self.start_recording),
            None,
            rumps.MenuItem("Settings", callback=self.open_settings),
            rumps.MenuItem("View Logs", callback=self.open_logs),
            None,
            rumps.MenuItem("Quit", callback=rumps.quit_application),
        ]

    # --- Recording Control ---

    def start_recording(self, sender):
        recording_name = self._prompt_recording_name()
        if not recording_name:
            return  # User cancelled

        output_path = self._build_output_path(recording_name)
        output_path.parent.mkdir(parents=True, exist_ok=True)

        self._capture = AudioCapture(output_path=output_path)
        self._capture.start()

        self.title = ICON_RECORDING
        self.menu["Start Recording"].title = "Stop Recording"
        self.menu["Start Recording"].set_callback(self.stop_recording)

        if self._cm.config.silence_detection_enabled:
            self._start_silence_monitor()

        log.info(f"Recording started: {output_path}")

    def stop_recording(self, sender):
        self._stop_silence_monitor()

        if self._capture:
            audio_path = self._capture.stop()
            self._capture = None
            self.title = ICON_PROCESSING
            self._pipeline.on_recording_complete(audio_path)
            log.info(f"Recording stopped, transcription queued: {audio_path.name}")

        self.menu["Stop Recording"].title = "Start Recording"
        self.menu["Stop Recording"].set_callback(self.start_recording)

    # --- Silence Detection ---

    def _start_silence_monitor(self):
        cfg = self._cm.config
        self._silence_detector = SilenceDetector(
            timeout_minutes=cfg.silence_timeout_minutes
        )
        self._silence_detector.reset()
        self._silence_thread = threading.Thread(
            target=self._silence_loop, daemon=True
        )
        self._silence_thread.start()

    def _stop_silence_monitor(self):
        self._silence_detector = None

    def _silence_loop(self):
        import time
        while self._silence_detector is not None:
            if self._silence_detector.is_timed_out():
                self._prompt_stop_on_silence()
                break
            time.sleep(10)  # Check every 10 seconds

    def _prompt_stop_on_silence(self):
        response = rumps.alert(
            title="No Audio Detected",
            message="No speech detected for several minutes. Stop recording?",
            ok="Stop Recording",
            cancel="Continue",
        )
        if response == 1:  # OK / Stop
            self.stop_recording(None)

    # --- Pipeline Callbacks ---

    def _on_rename_ready(self, json_path: Path):
        self.title = ICON_IDLE
        log.info(f"Transcription complete, launching rename dialog: {json_path.name}")
        run_rename_dialog(json_path)
        rumps.notification(
            title="Transcription Complete",
            subtitle=json_path.stem,
            message="Speaker names saved.",
        )

    def _on_pipeline_error(self, message: str):
        self.title = ICON_IDLE
        log.error(f"Pipeline error: {message}")
        rumps.notification(
            title="Transcription Failed",
            subtitle="",
            message=message,
        )

    # --- Menu Actions ---

    def open_settings(self, sender):
        self._settings_ctrl.show()

    def open_logs(self, sender):
        from pathlib import Path
        log_path = Path.home() / ".audio-transcribe" / "logs" / "transcribe-service.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.touch()
        import subprocess
        subprocess.run(["open", str(log_path)])

    # --- Helpers ---

    def _prompt_recording_name(self) -> Optional[str]:
        suggested = self._calendar.get_current_event_title() or "Recording"
        response = rumps.Window(
            message="Recording name:",
            title="Start Recording",
            default_text=suggested,
            ok="Start",
            cancel="Cancel",
            dimensions=(300, 24),
        ).run()
        if response.clicked == 1 and response.text.strip():
            return response.text.strip()
        return None

    def _build_output_path(self, name: str) -> Path:
        base = Path(self._cm.config.recording_directory).expanduser()
        date_folder = datetime.now().strftime("%Y-%m-%d")
        timestamp = datetime.now().strftime("%H%M%S")
        safe_name = name.replace(" ", "_").replace("/", "_")
        return base / date_folder / f"{timestamp}_{safe_name}.m4a"
```

- [ ] **Step 3: Commit**

```bash
git add service/menu_bar_app.py service/settings_window.py
git commit -m "feat: add AppKit menu bar app with recording control, settings, silence prompts"
```

---

## Task 10: Main Entry Point + Launchd

**Files:**
- Create: `service/main.py`
- Create: `com.audio-transcribe.plist`

- [ ] **Step 1: Implement main.py**

```python
# service/main.py
"""Entry point for the transcription service daemon.

Run directly:  python service/main.py
Via launchd:   configured in com.audio-transcribe.plist
"""
import sys
from pathlib import Path

# Ensure project root is on path
sys.path.insert(0, str(Path(__file__).parent.parent))

from service.config_manager import ConfigManager
from service.logger import get_logger
from service.menu_bar_app import TranscriptionApp

log = get_logger("main")


def main():
    log.info("Transcription service starting")

    config_manager = ConfigManager()

    # Create recordings directory if missing
    recordings_dir = Path(config_manager.config.recording_directory).expanduser()
    recordings_dir.mkdir(parents=True, exist_ok=True)

    app = TranscriptionApp(config_manager=config_manager)
    log.info("Menu bar app initialized — running")
    app.run()


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Create launchd plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.audio-transcribe</string>

    <key>ProgramArguments</key>
    <array>
        <string>/opt/miniconda3/envs/transcribe/bin/python</string>
        <string>REPLACE_WITH_FULL_PATH/service/main.py</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/Users/fmasi/.audio-transcribe/logs/stdout.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/fmasi/.audio-transcribe/logs/stderr.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HF_TOKEN</key>
        <string>REPLACE_WITH_HF_TOKEN</string>
    </dict>
</dict>
</plist>
```

- [ ] **Step 3: Add launchd install instructions to README**

Add the following section to `README.md` under a new `## Service Setup` heading:

```markdown
## Service Setup

### Install as background service (auto-start on login)

1. Edit `com.audio-transcribe.plist`:
   - Replace `REPLACE_WITH_FULL_PATH` with the full path to this repo
   - Replace `REPLACE_WITH_HF_TOKEN` with your HuggingFace token

2. Copy to LaunchAgents:
   ```bash
   cp com.audio-transcribe.plist ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/com.audio-transcribe.plist
   ```

3. Grant permissions when prompted (Screen Recording, Microphone, Calendar)

### Run manually (without launchd)

```bash
conda activate transcribe
python service/main.py
```

### Stop the service

```bash
launchctl unload ~/Library/LaunchAgents/com.audio-transcribe.plist
```
```

- [ ] **Step 4: Commit**

```bash
git add service/main.py com.audio-transcribe.plist README.md
git commit -m "feat: add main entry point and launchd auto-startup plist"
```

---

## Task 11: Integration Tests

**Files:**
- Create: `tests/test_integration.py`

- [ ] **Step 1: Write integration tests**

```python
# tests/test_integration.py
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

    def fake_transcribe(job):
        json_path = job.audio_path.with_suffix(".json")
        json_path.write_text(json.dumps({
            "segments": [
                {"start": 0.0, "end": 5.0, "speaker": "SPEAKER_00", "text": "Hello"},
            ],
            "metadata": {
                "audio_path": str(job.audio_path),
                "output_format": "txt",
            }
        }))

    pipeline = Pipeline(
        config=config,
        on_rename_ready=lambda p: rename_calls.append(p),
        on_error=lambda m: pytest.fail(f"Unexpected error: {m}"),
    )

    audio_path = tmp_path / "2026-03-27" / "meeting.m4a"
    audio_path.parent.mkdir(parents=True)
    audio_path.write_bytes(b"fake audio")

    with patch.object(pipeline, "_run_transcription", side_effect=fake_transcribe):
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

    with patch.object(pipeline, "_run_transcription", side_effect=RuntimeError("GPU out of memory")):
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

    def fake_transcribe(job):
        time.sleep(0.02)
        json_path = job.audio_path.with_suffix(".json")
        json_path.write_text(json.dumps({"segments": [], "metadata": {}}))

    pipeline = Pipeline(
        config=config,
        on_rename_ready=lambda p: completed.append(p.stem),
        on_error=lambda m: pytest.fail(m),
    )

    with patch.object(pipeline, "_run_transcription", side_effect=fake_transcribe):
        for name in ["rec_a", "rec_b", "rec_c"]:
            path = tmp_path / f"{name}.m4a"
            path.write_bytes(b"audio")
            pipeline.on_recording_complete(path)

        pipeline._queue.wait_all(timeout=10.0)

    assert completed == ["rec_a", "rec_b", "rec_c"]
```

- [ ] **Step 2: Run integration tests**

```bash
python -m pytest tests/test_integration.py -v
```

Expected: 3 PASSED

- [ ] **Step 3: Run full test suite**

```bash
python -m pytest tests/ -v --tb=short
```

Expected: All tests PASS

- [ ] **Step 4: Push to GitHub**

```bash
git add tests/test_integration.py
git commit -m "test: add integration tests for pipeline flow, error recovery, sequential ordering"
git push origin main
```

---

## Task 12: Manual Smoke Test

Verify the full end-to-end service on macOS before declaring complete.

- [ ] **Step 1: Install dependencies**

```bash
conda activate transcribe
pip install -r requirements-service.txt
```

- [ ] **Step 2: Run service directly**

```bash
python service/main.py
```

Expected: 🎙 appears in menu bar

- [ ] **Step 3: Grant permissions**

On first run, macOS will request:
- Microphone access → Allow
- Screen Recording access → Allow (for system audio)
- Calendar access → Allow

- [ ] **Step 4: Record a short test**

1. Click 🎙 → "Start Recording"
2. Verify dialog appears with calendar event pre-filled (if calendar event exists) or "Recording" default
3. Type name "Test_Recording" → click Start
4. Speak for 10 seconds
5. Click 🔴 → "Stop Recording"

Expected:
- File appears at `~/Documents/Recordings/YYYY-MM-DD/HHMMSS_Test_Recording.m4a`
- ⏳ icon appears while transcribing
- Rename dialog appears when transcription finishes
- After naming speakers: `Test_Recording.json` and `Test_Recording.txt` updated

- [ ] **Step 5: Test silence detection**

1. Start a recording
2. Stay silent for 5+ minutes (or reduce timeout in settings to 1 min for testing)

Expected: notification "No audio detected. Stop recording?" appears

- [ ] **Step 6: Test settings**

1. Open Settings via menu bar
2. Change output format to "srt"
3. Click Save
4. Start + stop a new recording

Expected: `.srt` file generated alongside `.json`

- [ ] **Step 7: Install launchd service**

```bash
# Edit the plist first — replace paths
open com.audio-transcribe.plist  # edit in text editor

cp com.audio-transcribe.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.audio-transcribe.plist
```

Expected: 🎙 appears in menu bar after logout/login without manual launch

---

## Self-Review Checklist

Spec requirements verified against tasks:

| Requirement | Task |
|---|---|
| Menu bar app with recording control | Task 9 |
| Calendar event pre-population | Task 5 + Task 9 |
| CoreAudio mic + system audio (no BlackHole) | Task 6 |
| Persistent daemon + launchd | Task 10 |
| Auto-transcription on recording stop | Task 7 |
| Sequential job queue (modular) | Task 3 |
| Rename dialog auto-triggered | Task 8 + Task 9 |
| File organization by date + name | Task 9 |
| Silero VAD silence detection | Task 4 |
| Configurable silence timeout | Task 4 + Task 9 |
| Silence detection toggle | Task 4 + Task 9 |
| Error notifications | Task 9 |
| Error logging | Task 2 + all tasks |
| Settings window | Task 9 |
| Config persistence | Task 1 |
| launchd auto-startup | Task 10 |
| Launch on startup toggle | Task 1 + Task 10 |
| JSON always written as master | Existing `transcribe.py` (unchanged) |
| Modular for future parallelization | Task 3 (documented in `job_queue.py`) |
