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

fetch() {
    local name="$1" url="$2"
    if [[ -f "$DIR/$name" ]]; then
        echo "==> $name already present"
        return
    fi
    echo "==> Fetching $name ..."
    curl -fL --progress-bar -o "$DIR/$name.part" "$url"
    mv "$DIR/$name.part" "$DIR/$name"
}

fetch "ES2004a.Mix-Headset.wav" \
    "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2004a/audio/ES2004a.Mix-Headset.wav"

echo
echo "==> Done. Fixtures in $DIR"
echo "    Run: swift test --filter DiarizationRegressionTests"
