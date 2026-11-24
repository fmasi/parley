"""Fetch the first N FLEURS test utterances per language as WAV + ground-truth.json (#339).

    HF_TOKEN=... python -I fetch-fleurs.py <out-dir> <parquet-cache-dir> ja_jp:50 ko_kr:50 cmn_hans_cn:50 en_us:20 ...
"""
import io, json, sys, os
from pathlib import Path
import pyarrow.parquet as pq, soundfile as sf
from huggingface_hub import hf_hub_download

out = Path(sys.argv[1]); pqdir = Path(sys.argv[2]); spec = sys.argv[3:]
out.mkdir(parents=True, exist_ok=True)
gt_path = out / "ground-truth.json"
gt = json.loads(gt_path.read_text()) if gt_path.exists() else {}
for item in spec:
    lang, n = item.split(":"); n = int(n)
    p = hf_hub_download("google/fleurs", f"{lang}/test/0000.parquet", repo_type="dataset",
                        revision="refs/convert/parquet", local_dir=str(pqdir))
    t = pq.read_table(p, columns=["audio", "transcription", "raw_transcription"])
    rows = []
    for i in range(min(n, len(t))):
        fn = f"{lang}-{i:02d}.wav"
        a = t.column("audio")[i].as_py()
        data, sr = sf.read(io.BytesIO(a["bytes"]))
        sf.write(str(out / fn), data, sr, subtype="PCM_16")
        rows.append({"file": fn, "text": t.column("transcription")[i].as_py(),
                     "raw": t.column("raw_transcription")[i].as_py(), "sr": sr,
                     "seconds": round(len(data) / sr, 2)})
    gt[lang] = rows
    print(lang, len(rows), "of", len(t), flush=True)
gt_path.write_text(json.dumps(gt, ensure_ascii=False, indent=1))
