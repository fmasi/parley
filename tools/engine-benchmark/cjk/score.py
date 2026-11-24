"""Score CJKBench result files (#339): CER per engine and language, language-tag accuracy, speed and memory.

    python -I score.py <ground-truth.json> <results.jsonl>...

CER, the same for every engine: NFKC, lowercase, every Unicode punctuation/symbol and all whitespace removed, Chinese
folded to Simplified (OpenCC t2s) on both sides, then character Levenshtein. Reported as the corpus CER (total edits /
total reference characters), and the mean of the per-clip CER the 2026-07-16 report used.
"""
import json
import sys
import unicodedata
from collections import Counter, defaultdict

import opencc

T2S = opencc.OpenCC("t2s")
CJK = {"ja_jp", "ko_kr", "cmn_hans_cn", "yue_hant_hk"}
# What a correct language tag looks like for each FLEURS config.
EXPECTED = {"ja_jp": "ja", "ko_kr": "ko", "cmn_hans_cn": "zh", "yue_hant_hk": "yue", "en_us": "en", "fr_fr": "fr",
            "es_419": "es", "pt_br": "pt", "de_de": "de", "it_it": "it"}
CJK_TAGS = {"ja", "ko", "zh", "yue"}


def norm(s, lang):
    s = unicodedata.normalize("NFKC", s or "").lower()
    s = "".join(c for c in s if not unicodedata.category(c)[0] in "PSZ" and not c.isspace())
    if lang in ("cmn_hans_cn", "yue_hant_hk"):
        s = T2S.convert(s)
    return s


def edits(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, cb in enumerate(b, 1):
            cur[j] = prev[j - 1] if ca == cb else 1 + min(prev[j - 1], prev[j], cur[j - 1])
        prev = cur
    return prev[-1]


def main():
    gt = json.load(open(sys.argv[1]))
    ref = {r["file"]: r["text"] for rows in gt.values() for r in rows}
    for path in sys.argv[2:]:
        load, summary, items = None, None, []
        for line in open(path):
            o = json.loads(line)
            if o["kind"] == "load":
                load = o
            elif o["kind"] == "summary":
                summary = o
            else:
                items.append(o)
        engine = (load or summary or {}).get("engine", path)
        print(f"\n## {engine}")
        if load and summary:
            print(f"load {load['load_seconds']:.1f} s; RTFx {summary['rtfx']:.1f}; peak footprint "
                  f"{summary['peak_footprint_mb']:.0f} MB; max RSS {summary['max_rss_mb']:.0f} MB")
        by_lang = defaultdict(list)
        for it in items:
            by_lang[it["lang"]].append(it)
        for lang, rows in sorted(by_lang.items()):
            errors = sum(1 for r in rows if "error" in r)
            line = f"{lang:12s} n={len(rows):3d}"
            if errors:
                line += f" errors={errors}"
            has_text = any(r.get("text") for r in rows)
            if lang in CJK and has_text:
                tot_e = tot_n = 0
                per = []
                for r in rows:
                    rr, hh = norm(ref[r["file"]], lang), norm(r.get("text", ""), lang)
                    e = edits(rr, hh)
                    tot_e += e
                    tot_n += len(rr)
                    per.append(e / max(len(rr), 1))
                line += f"  CER corpus {100 * tot_e / tot_n:5.1f}%  mean {100 * sum(per) / len(per):5.1f}%"
            tags = [r.get("tag") for r in rows if "tag" in r]
            if tags:
                exp = EXPECTED[lang]
                exact = sum(t == exp for t in tags)
                routed = sum(((t in CJK_TAGS) == (lang in CJK)) for t in tags)
                line += f"  tag exact {exact}/{len(tags)}  CJK-vs-not {routed}/{len(tags)}  {dict(Counter(tags))}"
            print(line)


if __name__ == "__main__":
    main()
