"""Captures microphone audio using AVAudioRecorder via PyObjC.

AVAudioRecorder runs inside the service process (python3.14) which already
holds the microphone TCC permission. This avoids the launchd subprocess
permission issue where ffmpeg/sounddevice fail to access audio hardware
when spawned indirectly from launchd.

Note: System audio capture (Zoom via headphones) requires a virtual loopback
device (BlackHole). Without one, only the microphone input is captured.
"""
import threading
from pathlib import Path
from typing import Optional

from service.logger import get_logger

log = get_logger("audio_capture")

try:
    import objc
    import AVFoundation as AVF
    import Foundation as F
    AVFOUNDATION_AVAILABLE = True
except ImportError:
    AVFOUNDATION_AVAILABLE = False
    log.warning("AVFoundation not available — audio capture disabled")


class AudioCapture:
    """Records microphone to a WAV file using AVAudioRecorder (PyObjC).

    Interface:
        capture = AudioCapture(output_path)
        capture.start()          # non-blocking
        path = capture.stop()    # stops and returns Path to WAV file
    """

    def __init__(self, output_path: Path):
        self._output_path = output_path
        self._recorder = None
        self._run_loop_thread: Optional[threading.Thread] = None
        self._run_loop = None

    def start(self) -> None:
        """Begin recording. Non-blocking."""
        if not AVFOUNDATION_AVAILABLE:
            log.error("Cannot start: AVFoundation not available")
            return

        self._output_path.parent.mkdir(parents=True, exist_ok=True)

        url = F.NSURL.fileURLWithPath_(str(self._output_path))

        settings = {
            AVF.AVFormatIDKey: int(AVF.kAudioFormatLinearPCM),
            AVF.AVSampleRateKey: 16000.0,
            AVF.AVNumberOfChannelsKey: 1,
            AVF.AVLinearPCMBitDepthKey: 16,
            AVF.AVLinearPCMIsBigEndianKey: False,
            AVF.AVLinearPCMIsFloatKey: False,
        }

        recorder, error = AVF.AVAudioRecorder.alloc().initWithURL_settings_error_(
            url, settings, None
        )

        if error is not None:
            log.error(f"AVAudioRecorder init failed: {error}")
            return

        if recorder is None:
            log.error("AVAudioRecorder init returned None")
            return

        self._recorder = recorder

        # AVAudioRecorder needs a run loop — spin one up on a background thread
        self._run_loop_thread = threading.Thread(
            target=self._run_loop_worker, daemon=True
        )
        self._run_loop_thread.start()

    def stop(self) -> Path:
        """Stop recording and return path to WAV file."""
        if self._recorder is not None:
            log.info("Stopping AVAudioRecorder...")
            self._recorder.stop()
            self._recorder = None

        if self._run_loop is not None:
            self._run_loop.performSelector_withObject_afterDelay_(
                b"stop", None, 0
            )
            self._run_loop = None

        if self._run_loop_thread is not None:
            self._run_loop_thread.join(timeout=5)
            self._run_loop_thread = None

        if not self._output_path.exists():
            log.error(f"Output file not found after stop: {self._output_path}")
            raise RuntimeError(f"AVAudioRecorder did not produce output: {self._output_path}")

        size = self._output_path.stat().st_size
        log.info(f"Audio written: {self._output_path.name} ({size // 1024} KB)")
        return self._output_path

    def _run_loop_worker(self) -> None:
        """Run an NSRunLoop on this thread so AVAudioRecorder can deliver callbacks."""
        import Foundation as F
        run_loop = F.NSRunLoop.currentRunLoop()
        self._run_loop = run_loop

        # Prepare and start recording once the run loop is live
        self._recorder.prepareToRecord()
        success = self._recorder.record()
        if success:
            log.info("AVAudioRecorder recording started")
        else:
            log.error("AVAudioRecorder.record() returned False — check microphone permission")

        # Run until stop() calls performSelector to break the loop
        run_loop.runUntilDate_(
            F.NSDate.dateWithTimeIntervalSinceNow_(3600)  # max 1 hour
        )
