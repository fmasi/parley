#!/usr/bin/env bash
# test-fresh.sh — Reset permissions, build, install, and launch for manual testing
#
# Usage:
#   bash scripts/test-fresh.sh
#
# Requires: conda environment activated (for Python embedding)
#
# What it does:
#   1. Kills running AudioTranscribe if any
#   2. Resets all TCC permissions for the app
#   3. Builds the app (debug) with embedded Python
#   4. Installs to /Applications
#   5. Launches the app

set -euo pipefail

BUNDLE_ID="com.audio-transcribe.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ -z "${CONDA_PREFIX:-}" ]]; then
    echo "ERROR: Activate your conda environment first."
    exit 1
fi

# ── Kill running instance ─────────────────────────────────────────────────────
echo "==> Killing AudioTranscribe if running..."
pkill -x AudioTranscribe 2>/dev/null || true
sleep 1

# ── Reset TCC permissions ────────────────────────────────────────────────────
echo "==> Resetting TCC permissions..."
tccutil reset Microphone "$BUNDLE_ID"
tccutil reset ScreenCapture "$BUNDLE_ID"
tccutil reset Calendar "$BUNDLE_ID"
# Notifications: tccutil doesn't support this service.
# To reset: System Settings > Notifications > AudioTranscribe > remove
echo "   Note: Notification permission cannot be reset via tccutil."
echo "   To reset: System Settings > Notifications > AudioTranscribe"

# ── Build + install ───────────────────────────────────────────────────────────
echo "==> Building and installing..."
bash package_app.sh --embed-python --install

# ── Launch ────────────────────────────────────────────────────────────────────
echo "==> Launching AudioTranscribe..."
open /Applications/AudioTranscribe.app

echo ""
echo "Done! The app should now show the permission setup window."
echo "Test checklist:"
echo "  1. Setup window appears with Grant buttons"
echo "  2. Grant Microphone — green checkmark"
echo "  3. Grant Screen Recording — green checkmark"
echo "  4. Continue button enables after both required permissions granted"
echo "  5. Click Continue — normal menu bar UI appears"
echo "  6. Start/stop a recording — full end-to-end test"
echo "  7. Quit and relaunch — no setup window (permissions remembered)"
