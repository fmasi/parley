"""Captures microphone audio using ffmpeg with the AVFoundation backend.

ffmpeg's AVFoundation input works correctly in launchd agent contexts where
PortAudio/sounddevice returns silence due to CoreAudio session differences.
Recording runs as a background ffmpeg subprocess; stop() terminates it.

Note: System audio capture (Zoom participants via headphones) requires a
virtual loopback device (e.g. BlackHole). Without one, only the microphone
input is captured.
"""
import subprocess
import threading
from pathlib import Path
from typing import Optional

from service.logger import get_logger

log = get_logger("audio_capture")

SAMPLE_RATE = 16_000
CHANNELS = 1
FFMPEG = "ffmpeg"


class AudioCapture:
    """Records microphone input to a WAV file via ffmpeg AVFoundation.

    Interface:
        capture = AudioCapture(output_path)
        capture.start()          # non-blocking
        path = capture.stop()    # blocks until ffmpeg flushes, returns Path
    """

    def __init__(self, output_path: Path):
        self._output_path = output_path
        self._process: Optional[subprocess.Popen] = None
        self._log_thread: Optional[threading.Thread] = None

    def start(self) -> None:
        """Begin capturing mic audio. Non-blocking."""
        self._output_path.parent.mkdir(parents=True, exist_ok=True)

        cmd = [
            FFMPEG,
            "-y",                          # overwrite without prompting
            "-f", "avfoundation",
            "-i", ":0",                    # first/default audio input device
            "-ar", str(SAMPLE_RATE),
            "-ac", str(CHANNELS),
            str(self._output_path),
        ]

        log.info(f"Starting ffmpeg AVFoundation capture → {self._output_path.name}")
        log.debug(f"Command: {' '.join(cmd)}")

        self._process = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        # Drain ffmpeg's stderr in background so it doesn't block
        self._log_thread = threading.Thread(
            target=self._drain_stderr, daemon=True
        )
        self._log_thread.start()

        # Give ffmpeg 1 second to either start capturing or fail
        import time
        time.sleep(1)
        if self._process.poll() is not None:
            log.error(f"ffmpeg exited immediately with code {self._process.returncode} — check [ffmpeg] lines above")
        else:
            log.info(f"Recording started — {SAMPLE_RATE} Hz mono via AVFoundation")

    def stop(self) -> Path:
        """Stop capture and flush WAV file. Returns path to written file."""
        if self._process is not None:
            log.info("Stopping ffmpeg (sending 'q')...")
            try:
                # ffmpeg stops cleanly when it receives 'q' on stdin,
                # but we used DEVNULL so we send SIGTERM instead.
                self._process.terminate()
                self._process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                log.warning("ffmpeg did not stop in time — killing")
                self._process.kill()
                self._process.wait()
            self._process = None

        if self._log_thread is not None:
            self._log_thread.join(timeout=5)
            self._log_thread = None

        if not self._output_path.exists():
            log.error(f"Expected output file not found: {self._output_path}")
            raise RuntimeError(f"ffmpeg did not produce output: {self._output_path}")

        size = self._output_path.stat().st_size
        log.info(f"Audio written: {self._output_path.name} ({size // 1024} KB)")
        return self._output_path

    def _drain_stderr(self) -> None:
        """Read ffmpeg stderr and forward lines to the service logger."""
        if self._process is None:
            return
        for raw in self._process.stderr:
            line = raw.decode("utf-8", errors="replace").rstrip()
            if line:
                log.info(f"[ffmpeg] {line}")
