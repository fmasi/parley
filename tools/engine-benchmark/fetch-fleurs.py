#!/usr/bin/env python3
"""Fetch the first N FLEURS `test` utterances per language as 16 kHz WAVs + ground-truth.json.

Used by the 2026-11-24 ASR model comparison (#350, #338); same sample as the 2026-07-16 report
(the first 50 rows of shard 0000 of the auto-converted parquet, per language).

Run inside a conda env (never pip on the host), e.g. the existing `transcribe` env:
    conda run -n transcribe python -I tools/engine-benchmark/fetch-fleurs.py OUT_DIR [--count 50]
Needs: huggingface_hub, pyarrow, soundfile, numpy. A token in ~/.cache/huggingface/token or
HF_TOKEN is used if FLEURS asks for one.
"""
import argparse
import io
import json
import pathlib

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf
from huggingface_hub import hf_hub_download

# FLEURS config -> file prefix the harness's inferLanguage() understands.
LANGS = {"en_us": "en", "es_419": "es", "fr_fr": "fr", "pt_br": "pt"}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out_dir")
    ap.add_argument("--count", type=int, default=50)
    ap.add_argument("--langs", default=",".join(LANGS))
    args = ap.parse_args()

    out = pathlib.Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    truth = {}
    for cfg in args.langs.split(","):
        prefix = LANGS[cfg]
        print(f"== {cfg}: downloading parquet shard 0000 ...", flush=True)
        path = hf_hub_download(
            "google/fleurs", f"{cfg}/test/0000.parquet",
            repo_type="dataset", revision="refs/convert/parquet",
        )
        table = pq.read_table(path, columns=["audio", "transcription"])
        rows = []
        for i in range(min(args.count, table.num_rows)):
            name = f"{prefix}-fleurs-{i:02d}.wav"
            text = table.column("transcription")[i].as_py()
            wav = out / name
            if not wav.exists():
                audio = table.column("audio")[i].as_py()
                data, sr = sf.read(io.BytesIO(audio["bytes"]), dtype="float32")
                if data.ndim > 1:
                    data = data.mean(axis=1)
                sf.write(str(wav), np.asarray(data), sr, subtype="PCM_16")
            rows.append({"file": name, "text": text})
        truth[cfg] = rows
        print(f"   {len(rows)} files", flush=True)
    (out / "ground-truth.json").write_text(json.dumps(truth, ensure_ascii=False, indent=1))
    print(f"wrote {out / 'ground-truth.json'}")


if __name__ == "__main__":
    main()
