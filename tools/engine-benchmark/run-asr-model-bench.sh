#!/bin/bash
# ASR model comparison for #350 (v3 Encoder_v2) and #338 (Parakeet Ultra), against v3 .int8 (today's default).
# Report: docs/benchmarks/2026-11-24-asr-v3-int8v2-ultra.md
#
# Runs AsrModelBench once per (configuration, data set), each in its own process under
# `/usr/bin/time -l`, so every run has its own load time and peak memory footprint. Then
# analyze-asr-model-bench.py prints WER per language, word diffs, RTFx, load time and peak memory.
#
# Usage:
#   bash tools/engine-benchmark/run-asr-model-bench.sh              # fetch data if missing, full pass
#   bash tools/engine-benchmark/run-asr-model-bench.sh --timing-only [--repeat N]
#       Re-run only the timing pass (needs the data and models a full pass fetched). Run it on an
#       idle Mac: no builds, no other apps transcribing. Results go to a new timing-<stamp>/ folder.
#   bash tools/engine-benchmark/run-asr-model-bench.sh --fleurs-full
#       Accuracy on the WHOLE FLEURS test split of each language (en 647, es 908, fr 676, pt 919
#       utterances) instead of the first 50; FLEURS only, no AMI. Results go to fleurs-full-<stamp>/.
#
# Data (fetched once into $BENCH): the first 50 FLEURS test utterances for en/es/fr/pt (the
# languages of the 2026-07-16 report), AMI ES2004a (the diarization fixture, 17.5 min) and AMI
# ES2010c (30.6 min), both Mix-Headset, with references built from the AMI manual word annotations.
# Python runs in the existing `transcribe` conda env (CONDA_ENV=... to change); never on the host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BENCH="${BENCH:-$HOME/Library/Application Support/Parley/benchmark/asr-350-338}"
CONDA_ENV="${CONDA_ENV:-transcribe}"
CONFIGS=(v3-int8 v3-int8v2 ultra)

timing_only=0
fleurs_full=0
repeat=1
while [ $# -gt 0 ]; do
    case "$1" in
        --timing-only) timing_only=1 ;;
        --repeat) repeat="$2"; shift ;;
        --fleurs-full) fleurs_full=1 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$BENCH/fleurs" "$BENCH/ami" "$BENCH/long" "$BENCH/models"

# ── Data ──
FLEURS="$BENCH/fleurs"
[ "$fleurs_full" = 1 ] && FLEURS="$BENCH/fleurs-full"
if [ ! -f "$FLEURS/ground-truth.json" ]; then
    count=50
    [ "$fleurs_full" = 1 ] && count=100000
    conda run --no-capture-output -n "$CONDA_ENV" python -I "$SCRIPT_DIR/fetch-fleurs.py" "$FLEURS" --count "$count"
fi
if [ ! -f "$BENCH/ami/ES2004a.Mix-Headset.wav" ]; then
    if [ -f "$REPO_ROOT/fixtures/diarization/ES2004a.Mix-Headset.wav" ]; then
        cp "$REPO_ROOT/fixtures/diarization/ES2004a.Mix-Headset.wav" "$BENCH/ami/"
    else
        curl -fL --max-time 600 --retry 3 -o "$BENCH/ami/ES2004a.Mix-Headset.wav" \
            https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2004a/audio/ES2004a.Mix-Headset.wav
    fi
fi
if [ ! -f "$BENCH/long/ES2010c.Mix-Headset.wav" ]; then
    curl -fL --max-time 900 --retry 3 --retry-delay 10 -o "$BENCH/long/ES2010c.Mix-Headset.wav" \
        https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2010c/audio/ES2010c.Mix-Headset.wav
fi
ANN="$BENCH/ami-annotations"
if [ ! -d "$ANN/x/words" ]; then
    mkdir -p "$ANN"
    curl -fL --max-time 600 --retry 3 -o "$ANN/ami_manual.zip" \
        https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip
    unzip -q -o "$ANN/ami_manual.zip" -d "$ANN/x"
fi
if [ ! -f "$BENCH/ami-ground-truth.json" ]; then
    python3 -I - "$SCRIPT_DIR/ami-reference.py" "$ANN/x/words" "$BENCH/ami-ground-truth.json" <<'PY'
import json, subprocess, sys
script, words, out = sys.argv[1:4]
ref = lambda m: subprocess.run([sys.executable, "-I", script, words, m], check=True,
                               capture_output=True, text=True).stdout.strip()
json.dump({"ami": [{"file": "ES2004a.Mix-Headset.wav", "text": ref("ES2004a")},
                   {"file": "ES2010c.Mix-Headset.wav", "text": ref("ES2010c")}]}, open(out, "w"), indent=1)
PY
fi

# ── Build ──
swift build -c release --package-path "$SCRIPT_DIR" --product AsrModelBench
BIN="$(swift build -c release --package-path "$SCRIPT_DIR" --show-bin-path)/AsrModelBench"

for c in "${CONFIGS[@]}"; do
    "$BIN" --config "$c" --models-dir "$BENCH/models" --download-only
done

# ── Runs ──
stamp="$(date +%Y%m%d-%H%M%S)"
if [ "$timing_only" = 1 ]; then OUT="$BENCH/timing-$stamp"
elif [ "$fleurs_full" = 1 ]; then OUT="$BENCH/fleurs-full-$stamp"
else OUT="$BENCH/run-$stamp"; fi
mkdir -p "$OUT"
load_start="$(sysctl -n vm.loadavg)"

run() {  # config set tag inputs...
    local c="$1" set="$2" tag="$3"; shift 3
    echo "── $c / $set ($tag) ──"
    /usr/bin/time -l "$BIN" --config "$c" --models-dir "$BENCH/models" \
        --out "$OUT/$c.$set.$tag.json" "$@" 2> "$OUT/$c.$set.$tag.time" | tail -1
    grep "peak memory footprint" "$OUT/$c.$set.$tag.time" || true
}

for r in $(seq 1 "$repeat"); do
    # Interleave configurations so a load spike does not land on one configuration only.
    for c in "${CONFIGS[@]}"; do run "$c" fleurs "r$r" "$FLEURS"; done
    [ "$fleurs_full" = 1 ] && continue
    for c in "${CONFIGS[@]}"; do run "$c" es2004a "r$r" "$BENCH/ami/ES2004a.Mix-Headset.wav"; done
    for c in "${CONFIGS[@]}"; do run "$c" es2010c "r$r" "$BENCH/long/ES2010c.Mix-Headset.wav"; done
done

{
    echo "machine: $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, macOS $(sw_vers -productVersion)"
    echo "load average at start: $load_start"
    echo "load average at end: $(sysctl -n vm.loadavg)"
} > "$OUT/machine.txt"

ARGS=("$OUT" --fleurs-gt "$FLEURS/ground-truth.json" --ami-gt "$BENCH/ami-ground-truth.json")
[ "$timing_only" = 1 ] && ARGS+=(--timing-only)
python3 -I "$SCRIPT_DIR/analyze-asr-model-bench.py" "${ARGS[@]}" | tee "$OUT/summary.md"
echo "Results: $OUT"
