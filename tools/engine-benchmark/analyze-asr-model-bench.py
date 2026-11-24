#!/usr/bin/env python3
"""Summarise an AsrModelBench run folder (run-asr-model-bench.sh): WER per language and file,
S/D/I, word diffs against the v3-int8 baseline, RTFx, load time and peak memory footprint.

Stdlib only:  python3 -I analyze-asr-model-bench.py RUN_DIR --fleurs-gt GT.json --ami-gt GT.json [--timing-only]

WER normalisation follows the engine-benchmark harness (normalizeForWER): lowercase, every
Unicode punctuation character except the apostrophe becomes a space, whitespace collapsed.
Corpus WER = total edits / total reference words over the language's files.
"""
import argparse
import collections
import difflib
import glob
import json
import os
import re
import statistics
import unicodedata

BASE = "v3-int8"
CONFIGS = ["v3-int8", "v3-int8v2", "ultra"]
# Disfluencies the AMI references transcribe and Ultra often leaves out (see the 2026-11-24 report).
FILLERS = {"um", "uh", "mm", "hmm", "mm-hmm", "uh-huh", "um-hmm", "mm-mm", "uh-uh"}
LANG_NAMES = {"en": "English", "es": "Spanish", "fr": "French", "pt": "Portuguese (pt-BR)"}


def norm(text):
    out = []
    for ch in text.lower():
        out.append(" " if unicodedata.category(ch).startswith("P") and ch != "'" else ch)
    return "".join(out).split()


def edits(ref, hyp):
    """Levenshtein alignment counts (S, D, I)."""
    n, m = len(ref), len(hyp)
    prev = [(j, 0, 0, j) for j in range(m + 1)]  # (cost, S, D, I)
    for i in range(1, n + 1):
        cur = [(i, 0, i, 0)] + [None] * m
        for j in range(1, m + 1):
            if ref[i - 1] == hyp[j - 1]:
                cur[j] = prev[j - 1]
                continue
            c, s, d, ins = prev[j - 1]
            best = (c + 1, s + 1, d, ins)
            c, s, d, ins = prev[j]
            if c + 1 < best[0]:
                best = (c + 1, s, d + 1, ins)
            c, s, d, ins = cur[j - 1]
            if c + 1 < best[0]:
                best = (c + 1, s, d, ins + 1)
            cur[j] = best
        prev = cur
    _, s, d, i = prev[m]
    return s, d, i


def load_gt(path):
    gt = {}
    for rows in json.load(open(path)).values():
        for r in rows:
            gt[r["file"]] = r["text"]
    return gt


def load_runs(run_dir):
    """{(config, set): [run dicts with 'peak' and 'tag']}"""
    runs = collections.defaultdict(list)
    for path in sorted(glob.glob(os.path.join(run_dir, "*.json"))):
        name = os.path.basename(path)
        parts = name[:-5].split(".")
        if len(parts) != 3:
            continue
        cfg, dset, tag = parts
        data = json.load(open(path))
        peak = None
        tpath = path[:-5] + ".time"
        if os.path.exists(tpath):
            m = re.search(r"(\d+)\s+peak memory footprint", open(tpath).read())
            if m:
                peak = int(m.group(1))
        data["peak"], data["tag"] = peak, tag
        runs[(cfg, dset)].append(data)
    return runs


def pct(x):
    return f"{100 * x:.2f}%"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir")
    ap.add_argument("--fleurs-gt", required=True)
    ap.add_argument("--ami-gt", required=True)
    ap.add_argument("--timing-only", action="store_true")
    ap.add_argument("--max-diffs", type=int, default=12)
    args = ap.parse_args()

    gt = load_gt(args.fleurs_gt) | load_gt(args.ami_gt)
    runs = load_runs(args.run_dir)
    sets = ["fleurs", "es2004a", "es2010c"]
    print(f"# AsrModelBench summary: {os.path.basename(os.path.abspath(args.run_dir))}\n")
    mpath = os.path.join(args.run_dir, "machine.txt")
    if os.path.exists(mpath):
        print("```\n" + open(mpath).read().strip() + "\n```\n")

    # ── Accuracy (first run of each config; decoding is deterministic) ──
    if not args.timing_only:
        texts = {}  # (cfg, file) -> words
        for (cfg, dset), rs in runs.items():
            for f in rs[0]["files"]:
                texts[(cfg, f["file"])] = norm(f.get("text", ""))
                if f.get("error"):
                    print(f"**error** {cfg} {f['file']}: {f['error']}\n")
        groups = collections.OrderedDict()
        files = sorted({f for (_, f) in texts})
        for f in files:
            if f.endswith("Mix-Headset.wav"):
                key = f.split(".")[0] + " (AMI)"
            else:
                key = LANG_NAMES.get(f[:2], f[:2])
            groups.setdefault(key, []).append(f)

        print("## WER (corpus: total edits / reference words)\n")
        print("| Set | Files | Ref words | " + " | ".join(CONFIGS) + " |")
        print("|---|---:|---:|" + "---:|" * len(CONFIGS))
        detail = []
        per_file = {}
        for key, fs in groups.items():
            refw = sum(len(norm(gt[f])) for f in fs if f in gt)
            cells = []
            for cfg in CONFIGS:
                tot = [0, 0, 0]
                for f in fs:
                    if f not in gt or (cfg, f) not in texts:
                        continue
                    s, d, i = edits(norm(gt[f]), texts[(cfg, f)])
                    per_file[(cfg, f)] = (s + d + i) / max(1, len(norm(gt[f])))
                    tot = [tot[0] + s, tot[1] + d, tot[2] + i]
                cells.append(pct(sum(tot) / max(1, refw)))
                detail.append((key, cfg, tot, refw, sum(len(texts.get((cfg, f), [])) for f in fs)))
            print(f"| {key} | {len(fs)} | {refw} | " + " | ".join(cells) + " |")

        print("\n## WER without fillers (" + ", ".join(sorted(FILLERS))
              + " removed from reference and hypothesis)\n")
        print("| Set | Ref words | " + " | ".join(CONFIGS) + " |")
        print("|---|---:|" + "---:|" * len(CONFIGS))
        strip = lambda ws: [w for w in ws if w not in FILLERS]
        for key, fs in groups.items():
            refs = {f: strip(norm(gt[f])) for f in fs if f in gt}
            refw = sum(len(r) for r in refs.values())
            cells = []
            for cfg in CONFIGS:
                err = sum(sum(edits(refs[f], strip(texts[(cfg, f)]))) for f in refs if (cfg, f) in texts)
                cells.append(pct(err / max(1, refw)))
            print(f"| {key} | {refw} | " + " | ".join(cells) + " |")

        print("\n## Errors by kind (S / D / I) and hypothesis word count\n")
        print("| Set | Config | Subst | Del | Ins | Hyp words |")
        print("|---|---|---:|---:|---:|---:|")
        for key, cfg, (s, d, i), refw, hypw in detail:
            print(f"| {key} | {cfg} | {s} | {d} | {i} | {hypw} |")

        print("\n## Files where WER moves vs v3-int8\n")
        for cfg in CONFIGS[1:]:
            better = worse = same = 0
            moved = []
            for f in files:
                if (BASE, f) not in per_file or (cfg, f) not in per_file:
                    continue
                a, b = per_file[(BASE, f)], per_file[(cfg, f)]
                if abs(a - b) < 1e-9:
                    same += 1
                else:
                    better += b < a
                    worse += b > a
                    moved.append((f, a, b))
            print(f"### {cfg}: {better} better, {worse} worse, {same} unchanged\n")
            for f, a, b in moved:
                base_w, cand_w = texts[(BASE, f)], texts[(cfg, f)]
                ops = [o for o in difflib.SequenceMatcher(None, base_w, cand_w, autojunk=False).get_opcodes()
                       if o[0] != "equal"]
                print(f"- `{f}` {pct(a)} → {pct(b)} ({len(ops)} diff spans)")
                for tag, i1, i2, j1, j2 in ops[: args.max_diffs]:
                    print(f"  - v3-int8 “{' '.join(base_w[i1:i2]) or '∅'}” → {cfg} “{' '.join(cand_w[j1:j2]) or '∅'}”")
                if len(ops) > args.max_diffs:
                    print(f"  - … {len(ops) - args.max_diffs} more")
            print()

    # ── Timing and memory ──
    print("## Speed, load time, peak memory footprint\n")
    print("| Set | Config | Runs | Audio s | RTFx (median) | Load s (median) | Peak footprint MB (max) |")
    print("|---|---|---:|---:|---:|---:|---:|")
    for dset in sets:
        for cfg in CONFIGS:
            rs = runs.get((cfg, dset), [])
            if not rs:
                continue
            audio = sum(f["durationSeconds"] for f in rs[0]["files"])
            rtf = statistics.median(audio / max(1e-9, sum(f["seconds"] for f in r["files"])) for r in rs)
            load = statistics.median(r["loadSeconds"] for r in rs)
            peaks = [r["peak"] for r in rs if r["peak"]]
            peak = f"{max(peaks) / 1048576:.0f}" if peaks else "?"
            print(f"| {dset} | {cfg} | {len(rs)} | {audio:.0f} | {rtf:.1f}× | {load:.2f} | {peak} |")


if __name__ == "__main__":
    main()
