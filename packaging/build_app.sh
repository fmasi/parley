#!/bin/bash
# Build AudioTranscribe.app — self-contained macOS .app bundle.
#
# Prerequisites:
#   - python.org framework Python 3.11 (not conda) on the build machine
#   - pip install relocatable-python
#   - Swift binary built: cd audio_capture_helper && bash build.sh
#
# Output:
#   dist/AudioTranscribe.app
#   dist/AudioTranscribe.dmg
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

APP_NAME="AudioTranscribe"
APP_DIR="$PROJECT_ROOT/dist/${APP_NAME}.app"
# Structure: Contents/MacOS and Contents/Resources
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
PYTHON_DEST="$RESOURCES/python"
APP_DEST="$RESOURCES/app"

echo "=== Building ${APP_NAME}.app ==="

# Step 1: Clean previous build
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES" "$APP_DEST/bin" "$APP_DEST/service"

# Step 2: Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"

# Step 3: Copy launcher
cp "$SCRIPT_DIR/launcher.sh" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

# Step 4: Copy app icon (optional — skip if not present)
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES/"
fi

# Step 5: Create relocatable Python with all dependencies
#   Uses Greg Neagle's relocatable-python to produce a standalone Python
#   from python.org's framework build. All deps installed directly into
#   site-packages. No venv, no conda.
#
#   See: https://github.com/gregneagle/relocatable-python
#   Verify exact CLI invocation against their docs — syntax may differ.
echo "--- Creating relocatable Python (this takes a few minutes) ---"
python3 -m relocatable_python \
    --destination "$PYTHON_DEST" \
    --python-version 3.11.9 \
    --pip-requirements "$PROJECT_ROOT/requirements-service.txt" \
    --pip-requirements "$PROJECT_ROOT/requirements-transcribe.txt"

# Step 6: Copy application source (mirrors repo layout for path resolution)
cp "$PROJECT_ROOT/transcribe.py" "$APP_DEST/"
cp "$PROJECT_ROOT/rename_speakers.py" "$APP_DEST/"
cp "$PROJECT_ROOT"/service/*.py "$APP_DEST/service/"

# Step 7: Copy Swift binary
if [ ! -f "$PROJECT_ROOT/bin/audio-capture-helper" ]; then
    echo "ERROR: bin/audio-capture-helper not found."
    echo "Build it first: cd audio_capture_helper && bash build.sh"
    exit 1
fi
cp "$PROJECT_ROOT/bin/audio-capture-helper" "$APP_DEST/bin/"

# Step 8: Ad-hoc code sign (replace '-' with Developer ID for distribution)
echo "--- Signing bundle ---"
codesign --force --deep --sign - "$APP_DIR"

echo "=== Built: $APP_DIR ==="

# Step 9: Create DMG
echo "--- Creating DMG ---"
hdiutil create -volname "Audio Transcribe" \
    -srcfolder "$APP_DIR" \
    -ov -format UDZO \
    "$PROJECT_ROOT/dist/${APP_NAME}.dmg"

echo "=== Done ==="
echo "App: $APP_DIR"
echo "DMG: $PROJECT_ROOT/dist/${APP_NAME}.dmg"
