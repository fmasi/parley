#!/usr/bin/env python3
"""Minimal diarization-only script for bridge period."""
import argparse
import json
import sys

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-i", "--input", required=True)
    parser.add_argument("--hf-token", required=True)
    parser.add_argument("-s", "--speakers", type=int)
    args = parser.parse_args()

    from pyannote.audio import Pipeline
    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        use_auth_token=args.hf_token
    )

    params = {}
    if args.speakers:
        params["num_speakers"] = args.speakers

    diarization = pipeline(args.input, **params)

    segments = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        segments.append({
            "start": turn.start,
            "end": turn.end,
            "speaker": speaker
        })

    json.dump(segments, sys.stdout)

if __name__ == "__main__":
    main()
