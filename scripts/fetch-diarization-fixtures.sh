#!/usr/bin/env bash
# Fetch reference audio for the diarization regression tests.
#
# AMI ES2004a is a 4-speaker scenario meeting from the AMI Meeting Corpus, freely mirrored by
# the University of Edinburgh. We use it as ground truth: the diarizer must find 4 speakers.
#
# This is the case that would have caught the `embeddingExcludeOverlap: false` bug, which
# collapsed every speaker into one and shipped for months — invisible to 1:1 device tests,
# because a two-party call has only one remote speaker to get wrong.
#
# Fixtures are git-ignored (33 MB); tests skip cleanly when they are absent.

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)/fixtures/diarization"
mkdir -p "$DIR"

# Verify what we downloaded. A truncated or corrupt fetch would otherwise be CACHED by CI and then
# fail the guard with "got 1 speaker instead of 4" — which is indistinguishable from the very
# regression the guard exists to catch. Fail loudly as a bad download instead.
fetch() {
    local name="$1" url="$2" sha="$3"
    if [[ -f "$DIR/$name" ]]; then
        echo "==> $name already present"
        return
    fi
    echo "==> Fetching $name ..."
    curl -fL --progress-bar -o "$DIR/$name.part" "$url"

    local actual
    actual="$(shasum -a 256 "$DIR/$name.part" | awk '{print $1}')"
    if [[ "$actual" != "$sha" ]]; then
        rm -f "$DIR/$name.part"
        echo "error: $name failed integrity check (download corrupt or truncated)" >&2
        echo "       expected $sha" >&2
        echo "       actual   $actual" >&2
        exit 1
    fi
    mv "$DIR/$name.part" "$DIR/$name"
}

fetch "ES2004a.Mix-Headset.wav" \
    "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2004a/audio/ES2004a.Mix-Headset.wav" \
    "3e2560b19bee6952c7c7ce041b0f1ea8a7ea9468044c4eea79d2a2c67e24ab0f"

echo
echo "==> Done. Fixtures in $DIR"
echo "    Run: swift test --filter DiarizationRegressionTests"
