#!/usr/bin/env python3
"""On-device audio transcription with speaker diarization.

Uses mlx-whisper (Apple Silicon optimized) for transcription
and pyannote.audio for speaker diarization.
"""

import argparse
import json
import os
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


def transcribe_audio(audio_path: str, language: str | None = None) -> dict:
    """Run mlx-whisper transcription."""
    import mlx_whisper

    print("Transcribing audio with mlx-whisper...")
    options = {
        "path_or_hf_repo": "mlx-community/whisper-large-v3-mlx",
        "word_timestamps": True,
        "verbose": True,
        "condition_on_previous_text": False,
        "compression_ratio_threshold": 1.8,
        "no_speech_threshold": 0.8,
    }
    if language:
        options["language"] = language

    result = mlx_whisper.transcribe(audio_path, **options)
    raw_count = len(result.get("segments", []))
    result["segments"] = deduplicate_segments(result.get("segments", []))
    clean_count = len(result["segments"])
    removed = raw_count - clean_count
    print(f"Transcription complete: {clean_count} segments ({removed} duplicates removed).")
    return result


def diarize_audio(
    audio_path: str, hf_token: str, num_speakers: int | None = None
) -> list[dict]:
    """Run pyannote speaker diarization."""
    from pyannote.audio import Pipeline

    print("Running speaker diarization with pyannote.audio...")
    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1", token=hf_token
    )

    # Use MPS (Metal) on Apple Silicon
    import torch

    if torch.backends.mps.is_available():
        pipeline.to(torch.device("mps"))
        print("Using Apple Metal (MPS) for diarization.")

    diarization_params = {}
    if num_speakers is not None:
        diarization_params["num_speakers"] = num_speakers

    # Normalise audio to 16kHz mono WAV to avoid pyannote sample-count mismatch
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_path = tmp.name
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-i", audio_path, "-ar", "16000", "-ac", "1", tmp_path],
            capture_output=True,
            check=True,
        )
        output = pipeline(tmp_path, **diarization_params)
    finally:
        os.unlink(tmp_path)

    # Unwrap pipeline output — different pyannote versions use different return types.
    # Walk all attributes to find the one that has itertracks (i.e. an Annotation).
    if hasattr(output, "itertracks"):
        diarization = output
    else:
        diarization = None
        for attr in vars(output) if hasattr(output, "__dict__") else []:
            val = getattr(output, attr)
            if hasattr(val, "itertracks"):
                diarization = val
                break
        if diarization is None:
            raise RuntimeError(
                f"Cannot extract diarization Annotation from {type(output).__name__}. "
                f"Available attributes: {list(vars(output).keys()) if hasattr(output, '__dict__') else 'N/A'}"
            )

    speaker_segments = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        speaker_segments.append(
            {"start": turn.start, "end": turn.end, "speaker": speaker}
        )

    speakers_found = len(set(s["speaker"] for s in speaker_segments))
    print(f"Diarization complete: {speakers_found} speakers detected.")
    return speaker_segments


def deduplicate_segments(segments: list[dict]) -> list[dict]:
    """Remove zero-duration and consecutively repeated segments."""
    cleaned = []
    last_text = None
    for seg in segments:
        # Drop zero-duration segments
        if seg["start"] == seg["end"]:
            continue
        # Drop consecutive duplicates
        text = seg["text"].strip()
        if text == last_text:
            continue
        last_text = text
        cleaned.append(seg)
    return cleaned


def assign_speakers(
    whisper_segments: list[dict], speaker_segments: list[dict]
) -> list[dict]:
    """Assign speaker labels to whisper segments based on time overlap."""
    # Build a consistent speaker name mapping (SPEAKER_00 -> Speaker 1)
    unique_speakers = []
    for seg in speaker_segments:
        if seg["speaker"] not in unique_speakers:
            unique_speakers.append(seg["speaker"])
    speaker_map = {s: f"Speaker {i + 1}" for i, s in enumerate(unique_speakers)}

    merged = []
    for seg in whisper_segments:
        seg_start = seg["start"]
        seg_end = seg["end"]
        seg_mid = (seg_start + seg_end) / 2

        best_speaker = "Unknown"
        best_overlap = 0

        for sp in speaker_segments:
            overlap_start = max(seg_start, sp["start"])
            overlap_end = min(seg_end, sp["end"])
            overlap = max(0, overlap_end - overlap_start)

            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = speaker_map.get(sp["speaker"], sp["speaker"])

            # Also check if midpoint falls within speaker segment
            if sp["start"] <= seg_mid <= sp["end"] and overlap >= best_overlap:
                best_speaker = speaker_map.get(sp["speaker"], sp["speaker"])

        merged.append(
            {
                "start": seg_start,
                "end": seg_end,
                "speaker": best_speaker,
                "text": seg["text"].strip(),
            }
        )

    return merged


def write_txt(segments: list[dict], output_path: str) -> None:
    """Write plain text output with timestamps and speaker labels."""
    with open(output_path, "w", encoding="utf-8") as f:
        for seg in segments:
            ts = format_timestamp_short(seg["start"])
            speaker = seg.get("speaker", "")
            prefix = f"[{ts}] {speaker}: " if speaker else f"[{ts}] "
            f.write(f"{prefix}{seg['text']}\n")


def write_srt(segments: list[dict], output_path: str) -> None:
    """Write SRT subtitle output."""
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
    """Write JSON output with segments and metadata."""
    output = {"metadata": metadata, "segments": segments}
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)


def transcribe_dual_stream(
    system_path: str,
    mic_path: str,
    hf_token: str | None,
    num_speakers: int | None,
    language: str | None,
    no_diarize: bool,
) -> list[dict]:
    """Transcribe two audio streams (system + mic) and merge by timestamp.

    Each stream is transcribed and diarized independently. Segments are tagged
    with a source prefix (Local/Remote) so speakers from different streams
    are distinguishable.
    """
    all_segments: list[dict] = []
    detected_language = None

    for audio_path, source_label in [(system_path, "Remote"), (mic_path, "Local")]:
        if not Path(audio_path).exists():
            print(f"Skipping {source_label} stream — file not found: {audio_path}")
            continue
        if Path(audio_path).stat().st_size <= 44:
            print(f"Skipping {source_label} stream — empty file: {audio_path}")
            continue

        print(f"\n--- Transcribing {source_label} stream: {audio_path} ---")
        result = transcribe_audio(audio_path, language=language or detected_language)
        if detected_language is None:
            detected_language = result.get("language")
        whisper_segments = result.get("segments", [])

        if not no_diarize and hf_token:
            speaker_segments = diarize_audio(
                audio_path, hf_token, num_speakers=num_speakers
            )
            segments = assign_speakers(whisper_segments, speaker_segments)
        else:
            segments = [
                {
                    "start": s["start"],
                    "end": s["end"],
                    "speaker": "",
                    "text": s["text"].strip(),
                }
                for s in whisper_segments
            ]

        # Tag each segment with its source
        for seg in segments:
            speaker = seg.get("speaker", "")
            if speaker and speaker != "Unknown":
                seg["speaker"] = f"{source_label} {speaker}"
            elif speaker != "Unknown":
                seg["speaker"] = f"{source_label}"
            seg["source"] = source_label.lower()

        all_segments.extend(segments)

    # Sort all segments chronologically
    all_segments.sort(key=lambda s: s["start"])
    return all_segments


def main():
    parser = argparse.ArgumentParser(
        description="On-device audio transcription with speaker diarization."
    )
    parser.add_argument(
        "-i", "--input", required=True, action="append",
        help="Path to audio file (can be specified twice for dual-stream: system + mic)",
    )
    parser.add_argument(
        "-o", "--output", help="Output file path (default: auto from input name)"
    )
    parser.add_argument(
        "-f",
        "--format",
        choices=["txt", "srt", "json"],
        default="txt",
        help="Output format (default: txt)",
    )
    parser.add_argument(
        "-s", "--speakers", type=int, help="Number of speakers (auto-detect if omitted)"
    )
    parser.add_argument(
        "-l", "--language", help="Force language code, e.g. en, it (auto-detect if omitted)"
    )
    parser.add_argument(
        "--no-diarize",
        action="store_true",
        help="Skip speaker diarization (faster, timestamps only)",
    )
    parser.add_argument(
        "--hf-token",
        default=os.environ.get("HF_TOKEN"),
        help="HuggingFace token (or set HF_TOKEN env var)",
    )

    args = parser.parse_args()

    # Validate inputs exist
    audio_paths = [Path(p) for p in args.input]
    primary_path = audio_paths[0]
    for p in audio_paths:
        if not p.exists():
            print(f"Error: audio file not found: {p}")
            sys.exit(1)

    # Determine output path
    if args.output:
        output_path = args.output
    else:
        output_path = str(primary_path.with_suffix(f".{args.format}"))

    # Validate diarization requirements
    if not args.no_diarize and not args.hf_token:
        print("Error: speaker diarization requires a HuggingFace token.")
        print("Set HF_TOKEN env var or pass --hf-token.")
        print("Or use --no-diarize to skip speaker detection.")
        sys.exit(1)

    # Dual-stream mode: two inputs = system + mic
    if len(audio_paths) == 2:
        segments = transcribe_dual_stream(
            system_path=str(audio_paths[0]),
            mic_path=str(audio_paths[1]),
            hf_token=args.hf_token,
            num_speakers=args.speakers,
            language=args.language,
            no_diarize=args.no_diarize,
        )
        detected_language = "auto"
    else:
        # Single-file mode (backward compatible)
        result = transcribe_audio(str(primary_path), language=args.language)
        whisper_segments = result.get("segments", [])
        detected_language = result.get("language", "auto")

        if not args.no_diarize:
            speaker_segments = diarize_audio(
                str(primary_path), args.hf_token, num_speakers=args.speakers
            )
            segments = assign_speakers(whisper_segments, speaker_segments)
        else:
            segments = [
                {
                    "start": s["start"],
                    "end": s["end"],
                    "speaker": "",
                    "text": s["text"].strip(),
                }
                for s in whisper_segments
            ]

    # Write output
    metadata = {
        "audio_files": [str(p.name) for p in audio_paths],
        "audio_paths": [str(p.resolve()) for p in audio_paths],
        "output_format": args.format,
        "language": detected_language,
        "num_speakers": args.speakers or "auto",
        "diarization": not args.no_diarize,
        "dual_stream": len(audio_paths) == 2,
    }

    # Always write JSON as the master copy so the expensive run never needs repeating.
    json_path = str(primary_path.with_suffix(".json"))
    write_json(segments, json_path, metadata)

    if args.format == "txt":
        write_txt(segments, output_path)
    elif args.format == "srt":
        write_srt(segments, output_path)
    elif args.format == "json":
        output_path = json_path  # already written above

    if args.format != "json":
        print(f"Master JSON saved to: {json_path}")
    print(f"Output saved to:      {output_path}")


if __name__ == "__main__":
    main()
