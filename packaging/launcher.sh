#!/bin/bash
set -euo pipefail
# Launcher for AudioTranscribe.app
# Sets up the embedded Python environment and exec's the service.
# exec replaces this shell — Python becomes the app process,
# so TCC grants flow through to subprocesses (audio-capture-helper).

DIR="$(cd "$(dirname "$0")" && pwd)"
CONTENTS="$DIR/.."
RESOURCES="$CONTENTS/Resources"
PYTHON_FRAMEWORK="$RESOURCES/python/Python.framework/Versions/3.11"
PYTHON="$PYTHON_FRAMEWORK/bin/python3"
APP_ROOT="$RESOURCES/app"

# Embedded Python uses only bundled stdlib + site-packages
export PYTHONHOME="$PYTHON_FRAMEWORK"
export PYTHONPATH="$APP_ROOT"
export PYTHONDONTWRITEBYTECODE=1

# Include Homebrew so ffmpeg (required by mlx_whisper) is found
export PATH="$PYTHON_FRAMEWORK/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

exec "$PYTHON" "$APP_ROOT/service/main.py"
