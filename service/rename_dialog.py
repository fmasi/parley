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
    if not APPKIT_AVAILABLE:
        log.warning("AppKit not available — skipping GUI prompt for %s", speaker)
        return None

    # Play audio sample
    try:
        _play_sample(audio_path, sample["start"], sample["end"])
    except Exception as e:
        log.warning(f"Could not play sample: {e}")

    alert = NSAlert.alloc().init()
    alert.setMessageText_(f"Who is {speaker}?")
    alert.setInformationalText_(
        f'Sample: "{sample["text"][:100]}"\n'
        f"({sample['start']:.0f}s - {sample['end']:.0f}s)"
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
    if not APPKIT_AVAILABLE:
        log.error("AppKit not available — cannot show error dialog: %s", message)
        return

    alert = NSAlert.alloc().init()
    alert.setMessageText_("Transcription Service Error")
    alert.setInformationalText_(message)
    alert.runModal()
