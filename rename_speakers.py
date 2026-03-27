#!/usr/bin/env python3
"""Interactive speaker renaming tool.

Reads JSON output from transcribe.py, plays audio samples of each speaker,
and prompts for real names. Outputs renamed transcript in any format.
"""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def format_timestamp(seconds: float) -> str:
    """Convert seconds to HH:MM:SS,mmm format."""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int((seconds % 1) * 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def format_timestamp_short(seconds: float) -> str:
    """Convert seconds to HH:MM:SS format."""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def find_speaker_samples(segments: list[dict], sample_duration: float = 10.0) -> dict:
    """Find a good audio sample for each speaker.

    Picks the longest continuous stretch for each speaker, up to sample_duration.
    """
    speakers = {}
    for seg in segments:
        speaker = seg["speaker"]
        if not speaker or speaker == "Unknown":
            continue
        duration = seg["end"] - seg["start"]
        if speaker not in speakers or duration > (
            speakers[speaker]["end"] - speakers[speaker]["start"]
        ):
            speakers[speaker] = {
                "start": seg["start"],
                "end": min(seg["start"] + sample_duration, seg["end"]),
                "text": seg["text"],
            }
    return speakers


def play_sample(audio_path: str, start: float, end: float) -> None:
    """Extract and play an audio clip using ffmpeg + afplay."""
    duration = end - start
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as tmp:
        cmd = [
            "ffmpeg",
            "-y",
            "-ss", str(start),
            "-t", str(duration),
            "-i", audio_path,
            "-ar", "16000",
            "-ac", "1",
            tmp.name,
        ]
        subprocess.run(cmd, capture_output=True, check=True)
        subprocess.run(["afplay", tmp.name], check=True)


def prompt_speaker_names(
    speakers: dict, audio_path: str
) -> dict[str, str]:
    """Interactively prompt user to name each speaker."""
    name_map = {}
    print(f"\nFound {len(speakers)} speakers. Playing samples...\n")

    for speaker, sample in sorted(speakers.items()):
        print(f"--- {speaker} ---")
        print(f"  Sample text: \"{sample['text'][:80]}...\"")

        while True:
            try:
                print(f"  Playing audio sample ({sample['start']:.1f}s - {sample['end']:.1f}s)...")
                play_sample(audio_path, sample["start"], sample["end"])
            except (subprocess.CalledProcessError, FileNotFoundError) as e:
                print(f"  Could not play audio: {e}")
                print("  (Make sure ffmpeg is installed: brew install ffmpeg)")

            response = input(f"  Who is {speaker}? (enter name, 'r' to replay, or press Enter to keep label): ").strip()

            if response.lower() == "r":
                continue
            elif response:
                name_map[speaker] = response
                print(f"  -> {speaker} = {response}\n")
            else:
                name_map[speaker] = speaker
                print(f"  -> Keeping as {speaker}\n")
            break

    return name_map


def apply_names(segments: list[dict], name_map: dict[str, str]) -> list[dict]:
    """Replace speaker labels with real names."""
    return [
        {**seg, "speaker": name_map.get(seg["speaker"], seg["speaker"])}
        for seg in segments
    ]


def write_txt(segments: list[dict], output_path: str) -> None:
    with open(output_path, "w", encoding="utf-8") as f:
        for seg in segments:
            ts = format_timestamp_short(seg["start"])
            speaker = seg.get("speaker", "")
            prefix = f"[{ts}] {speaker}: " if speaker else f"[{ts}] "
            f.write(f"{prefix}{seg['text']}\n")


def write_srt(segments: list[dict], output_path: str) -> None:
    with open(output_path, "w", encoding="utf-8") as f:
        for i, seg in enumerate(segments, 1):
            start = format_timestamp(seg["start"])
            end = format_timestamp(seg["end"])
            speaker = seg.get("speaker", "")
            prefix = f"{speaker}: " if speaker else ""
            f.write(f"{i}\n")
            f.write(f"{start} --> {end}\n")
            f.write(f"{prefix}{seg['text']}\n\n")


def write_json(segments: list[dict], output_path: str, metadata: dict) -> None:
    output = {"metadata": metadata, "segments": segments}
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)


def main():
    parser = argparse.ArgumentParser(
        description="Interactively rename speakers in a transcript."
    )
    parser.add_argument(
        "-i", "--input", required=True, help="JSON transcript from transcribe.py"
    )
    parser.add_argument(
        "-a", "--audio", help="Original audio file (auto-resolved from JSON if omitted)"
    )
    parser.add_argument("-o", "--output", help="Output file path (default: overwrites original)")
    parser.add_argument(
        "-f",
        "--format",
        choices=["txt", "srt", "json"],
        help="Output format (default: taken from JSON metadata)",
    )

    args = parser.parse_args()

    # Load JSON transcript
    input_path = Path(args.input)
    if not input_path.exists():
        print(f"Error: transcript not found: {input_path}")
        sys.exit(1)

    with open(input_path, encoding="utf-8") as f:
        data = json.load(f)

    segments = data["segments"]
    metadata = data.get("metadata", {})

    # Resolve audio path: flag > JSON metadata > error
    if args.audio:
        audio_path = Path(args.audio)
    elif metadata.get("audio_path"):
        audio_path = Path(metadata["audio_path"])
    else:
        print("Error: audio file not specified and not found in JSON metadata.")
        print("Pass it with --audio.")
        sys.exit(1)

    if not audio_path.exists():
        print(f"Error: audio file not found: {audio_path}")
        print("The file may have been moved. Pass the current path with --audio.")
        sys.exit(1)

    # Resolve output format: flag > JSON metadata > txt
    fmt = args.format or metadata.get("output_format", "txt")

    # Find samples and prompt for names
    speaker_samples = find_speaker_samples(segments)
    if not speaker_samples:
        print("No speakers found in transcript.")
        sys.exit(1)

    name_map = prompt_speaker_names(speaker_samples, str(audio_path))
    renamed_segments = apply_names(segments, name_map)

    # Determine output path: flag > overwrite original file in the requested format
    if args.output:
        output_path = args.output
    else:
        output_path = str(input_path.with_suffix(f".{fmt}"))

    # Update metadata
    metadata["speaker_names"] = name_map

    # Always update the master JSON too
    write_json(renamed_segments, str(input_path), metadata)

    # Write requested format
    if fmt == "txt":
        write_txt(renamed_segments, output_path)
    elif fmt == "srt":
        write_srt(renamed_segments, output_path)
    elif fmt == "json":
        output_path = str(input_path)  # already written above

    if fmt != "json":
        print(f"Master JSON updated:       {input_path}")
    print(f"Named transcript saved to: {output_path}")


if __name__ == "__main__":
    main()
