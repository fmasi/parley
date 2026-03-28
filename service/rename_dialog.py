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

# Guard: AppKit/PyObjC may not be installed in all environments
APPKIT_AVAILABLE = False
try:
    import objc  # noqa: F401
    from AppKit import (
        NSAlert,
        NSTextField,
        NSApplication,
        NSInformationalAlertStyle,
    )
    from Foundation import NSObject  # noqa: F401

    APPKIT_AVAILABLE = True
except ImportError:
    log.warning(
        "PyObjC not available — rename_dialog GUI disabled. "
        "Install pyobjc-framework-Cocoa to enable."
    )


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
    fmt = metadata.get("output_format", "txt")

    audio_paths = metadata.get("audio_paths", [])
    # Build source→audio_path mapping for dual-stream recordings
    audio_path_map = {}
    if len(audio_paths) >= 2:
        audio_path_map["remote"] = Path(audio_paths[0])
        audio_path_map["local"] = Path(audio_paths[1])
    elif len(audio_paths) == 1:
        audio_path_map["remote"] = Path(audio_paths[0])
        audio_path_map["local"] = Path(audio_paths[0])

    if not any(p.exists() for p in audio_path_map.values()):
        log.error(f"No audio files found for rename: {audio_paths}")
        _show_error(f"Audio files not found:\n{audio_paths}\n\nCannot play samples.")
        return

    speaker_samples = find_speaker_samples(segments)
    if not speaker_samples:
        log.warning("No speakers found in transcript — skipping rename")
        return

    name_map = {}
    for speaker, sample in sorted(speaker_samples.items()):
        source = sample.get("source", "remote")
        audio_path = audio_path_map.get(source, audio_path_map.get("remote"))
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
    """Show an NSAlert dialog asking user to name a speaker.

    Dialog shows sample text immediately with a Play Sample button for
    optional non-blocking audio playback.
    """
    if not APPKIT_AVAILABLE:
        log.warning("AppKit not available — skipping GUI prompt for %s", speaker)
        return None

    # Pre-extract the audio clip so playback is instant when requested
    sample_file = _extract_sample(audio_path, sample["start"], sample["end"])

    input_field = NSTextField.alloc().initWithFrame_(((0, 0), (300, 24)))
    input_field.setPlaceholderString_(speaker)

    playback_proc = None

    while True:
        alert = NSAlert.alloc().init()
        alert.setMessageText_(f"Who is {speaker}?")
        alert.setInformativeText_(
            f'"{sample["text"][:120]}"\n'
            f"({sample['start']:.0f}s – {sample['end']:.0f}s)"
        )
        alert.setAlertStyle_(NSInformationalAlertStyle)
        alert.addButtonWithTitle_("OK")          # 1000
        alert.addButtonWithTitle_("Skip")        # 1001
        alert.addButtonWithTitle_("Play Sample") # 1002
        alert.setAccessoryView_(input_field)
        # Focus the text field so user can type immediately
        alert.window().setInitialFirstResponder_(input_field)

        response = alert.runModal()

        if response == 1002:  # Play Sample
            # Kill any previous playback, start new one non-blocking
            if playback_proc and playback_proc.poll() is None:
                playback_proc.terminate()
            if sample_file:
                playback_proc = subprocess.Popen(
                    ["afplay", sample_file],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            continue  # Re-show the dialog

        # Stop any ongoing playback on OK/Skip
        if playback_proc and playback_proc.poll() is None:
            playback_proc.terminate()

        # Clean up temp file
        if sample_file:
            try:
                Path(sample_file).unlink(missing_ok=True)
            except Exception:
                pass

        entered = str(input_field.stringValue()).strip()
        if response == 1000 and entered:  # OK clicked with text
            return entered
        return None


def _extract_sample(audio_path: str, start: float, end: float) -> Optional[str]:
    """Extract an audio clip to a temp file. Returns path or None on failure."""
    duration = end - start
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    try:
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
        return tmp.name
    except Exception as e:
        log.warning(f"Could not extract sample: {e}")
        try:
            Path(tmp.name).unlink(missing_ok=True)
        except Exception:
            pass
        return None


def _show_error(message: str) -> None:
    if not APPKIT_AVAILABLE:
        log.error("AppKit not available — cannot show error dialog: %s", message)
        return

    alert = NSAlert.alloc().init()
    alert.setMessageText_("Transcription Service Error")
    alert.setInformativeText_(message)
    alert.runModal()
