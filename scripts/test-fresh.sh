#!/usr/bin/env bash
# test-fresh.sh — Build, install, and launch for manual testing
#
# Usage:
#   bash scripts/test-fresh.sh              # build + install + launch
#   bash scripts/test-fresh.sh --reset-tcc  # also reset TCC permissions first
#
# Requires: conda environment activated (for Python embedding)

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

# ── Optionally reset TCC permissions ────────────────────────────────────────
if [[ "${1:-}" == "--reset-tcc" ]]; then
    echo "==> Resetting TCC permissions..."
    tccutil reset Microphone "$BUNDLE_ID"
    tccutil reset ScreenCapture "$BUNDLE_ID"
    tccutil reset Calendar "$BUNDLE_ID"
    echo "   Note: Notification permission cannot be reset via tccutil."
    echo "   To reset: System Settings > Notifications > AudioTranscribe"
else
    echo "==> Skipping TCC reset (use --reset-tcc to reset permissions)"
fi

# ── Build + install ───────────────────────────────────────────────────────────
echo "==> Building and installing..."
bash package_app.sh --embed-python --install

# ── Launch ────────────────────────────────────────────────────────────────────
echo "==> Launching AudioTranscribe..."
open /Applications/AudioTranscribe.app

echo ""
echo "Done!"
echo ""
echo "=== Test Checklist ==="
echo ""
echo "Microphone Picker:"
echo "  1. Click Start Recording — session name dialog appears"
echo "  2. Mic dropdown shows 'System Default' + all real input devices"
echo "  3. Select a non-default mic — level meter shows input from THAT device only"
echo "  4. Speak into selected mic — green/yellow bar animates"
echo "  5. Click Start Recording — recording starts normally"
echo "  6. Stop recording — transcription runs"
echo "  7. Start another recording — last-used mic is pre-selected"
echo ""
echo "Recording end-to-end:"
echo "  8. Start/stop a recording with system default mic"
echo "  9. Verify _mic.wav has audio from the correct device"
echo "  10. Quit and relaunch — permissions still granted, no setup window"
