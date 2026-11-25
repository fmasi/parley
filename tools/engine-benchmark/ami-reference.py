#!/usr/bin/env python3
"""Build a whole-meeting reference transcript for an AMI meeting from the manual word annotations.

Reads <words_dir>/<meeting>.<spk>.words.xml for every speaker (ami_public_manual_1.6.2.zip,
https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/), keeps the <w> elements that are not
punctuation, sorts them by start time across speakers and prints one line of text. With
--durations, prints each meeting's last word end time instead (to pick a ~30 min meeting).

Stdlib only:  python3 -I tools/engine-benchmark/ami-reference.py WORDS_DIR ES2004a
"""
import argparse
import collections
import pathlib
import re
import xml.etree.ElementTree as ET


def words(path: pathlib.Path):
    for el in ET.parse(path).getroot().iter():
        if el.tag.split("}")[-1] != "w" or el.get("punc") == "true":
            continue
        text = (el.text or "").strip()
        start = el.get("starttime")
        if text and start is not None:
            yield float(start), float(el.get("endtime") or start), text


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("words_dir")
    ap.add_argument("meeting", nargs="?")
    ap.add_argument("--durations", action="store_true")
    args = ap.parse_args()
    d = pathlib.Path(args.words_dir)
    if args.durations:
        ends = collections.defaultdict(float)
        for f in d.glob("*.words.xml"):
            m = f.name.split(".")[0]
            for _, e, _ in words(f):
                ends[m] = max(ends[m], e)
        for m, e in sorted(ends.items()):
            print(f"{m}\t{e/60:.1f} min")
        return
    allw = []
    for f in sorted(d.glob(f"{args.meeting}.*.words.xml")):
        allw.extend(words(f))
    allw.sort()
    text = " ".join(w for _, _, w in allw)
    print(re.sub(r"\s+", " ", text))


if __name__ == "__main__":
    main()
