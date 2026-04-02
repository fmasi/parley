#!/bin/bash
# Run the full ASR engine benchmark matrix across all test audio files.
#
# Prerequisites:
#   1. Download test audio: python3 tools/engine-benchmark/download-test-audio.py
#   2. Build benchmark:     swift build --package-path tools/engine-benchmark
#
# Usage:
#   bash tools/engine-benchmark/run-benchmark-matrix.sh [--engines fluid,whisper-cpp,speech]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$HOME/.audio-transcribe/benchmark/test-audio"

# Check test audio exists
if [ ! -d "$TEST_DIR" ] || [ -z "$(ls -A "$TEST_DIR"/*.wav 2>/dev/null)" ]; then
    echo "No test audio found. Downloading..."
    python3 "$SCRIPT_DIR/download-test-audio.py"
fi

# Pass through any arguments (e.g. --engines fluid,speech)
echo "Running batch benchmark..."
echo "Test audio: $TEST_DIR"
echo ""

swift run --package-path "$SCRIPT_DIR" EngineBenchmark \
    --batch "$TEST_DIR" \
    "$@"
