#!/bin/bash
set -euo pipefail
# Launcher for AudioTranscribe.app
# Sets up the embedded Python environment and exec's the service.
# exec replaces this shell — Python becomes the app process,
# so TCC grants flow through to subprocesses (audio-capture-helper).

DIR="$(cd "$(dirname "$0")" && pwd)"
CONTENTS="$DIR/.."
RESOURCES="$CONTENTS/Resources"
PYTHON="$RESOURCES/python/bin/python3"
APP_ROOT="$RESOURCES/app"

# Embedded Python uses only bundled stdlib + site-packages
export PYTHONHOME="$RESOURCES/python"
export PYTHONPATH="$APP_ROOT"
export PYTHONDONTWRITEBYTECODE=1

# Minimal PATH for runtime
export PATH="$RESOURCES/python/bin:/usr/bin:/bin"

exec "$PYTHON" "$APP_ROOT/service/main.py"
