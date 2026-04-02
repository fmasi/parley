#!/usr/bin/env python3
"""
Standalone pyannote diarization for comparison testing.
Uses the pyannote/speaker-diarization-3.1 pipeline (compatible with pyannote.audio 3.x and 4.x).

Usage:
    python tools/pyannote-diarize.py <audio.wav> --hf-token <TOKEN>
    python tools/pyannote-diarize.py <audio.wav> --hf-token <TOKEN> --num-speakers 3

Requires conda env with: pip install pyannote.audio torch
"""
import argparse
import json
import sys
import time


def main():
    parser = argparse.ArgumentParser(description="pyannote 3.1 speaker diarization")
    parser.add_argument("audio", help="Path to audio file")
    parser.add_argument("--hf-token", required=True, help="HuggingFace auth token")
    parser.add_argument("--num-speakers", type=int, help="Expected number of speakers")
    parser.add_argument("--min-speakers", type=int, help="Minimum speakers")
    parser.add_argument("--max-speakers", type=int, help="Maximum speakers")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    args = parser.parse_args()

    print(f"Loading pyannote/speaker-diarization-3.1...", file=sys.stderr)
    load_start = time.time()

    from pyannote.audio import Pipeline

    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        token=args.hf_token,
    )
    print(f"Model loaded in {time.time() - load_start:.1f}s", file=sys.stderr)

    params = {}
    if args.num_speakers:
        params["num_speakers"] = args.num_speakers
    if args.min_speakers:
        params["min_speakers"] = args.min_speakers
    if args.max_speakers:
        params["max_speakers"] = args.max_speakers

    print(f"Diarizing: {args.audio}", file=sys.stderr)
    if params:
        print(f"Constraints: {params}", file=sys.stderr)

    diarize_start = time.time()
    result = pipeline(args.audio, **params)
    diarize_elapsed = time.time() - diarize_start

    # pyannote 4.x returns DiarizeOutput; 3.x returns Annotation directly
    if hasattr(result, "serialize"):
        serialized = result.serialize()
        segments = serialized["diarization"]
    else:
        segments = []
        for turn, _, speaker in result.itertracks(yield_label=True):
            segments.append({
                "start": round(turn.start, 3),
                "end": round(turn.end, 3),
                "speaker": speaker,
            })

    speakers = {}
    for seg in segments:
        sp = seg["speaker"]
        speakers[sp] = speakers.get(sp, 0) + 1

    print(f"\nResults:", file=sys.stderr)
    print(f"  Time: {diarize_elapsed:.1f}s", file=sys.stderr)
    print(f"  Speakers: {len(speakers)}", file=sys.stderr)
    print(f"  Segments: {len(segments)}", file=sys.stderr)
    for sp, count in sorted(speakers.items(), key=lambda x: -x[1]):
        print(f"    {sp}: {count} segments", file=sys.stderr)

    if args.json:
        json.dump({"segments": segments, "speakers": speakers}, sys.stdout, indent=2)
    else:
        for seg in segments[:10]:
            start = f"{int(seg['start'])//60:02d}:{int(seg['start'])%60:02d}"
            end = f"{int(seg['end'])//60:02d}:{int(seg['end'])%60:02d}"
            print(f"  [{start}-{end}] {seg['speaker']}")
        if len(segments) > 10:
            print(f"  ... ({len(segments) - 10} more segments)")


if __name__ == "__main__":
    main()
