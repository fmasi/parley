#!/bin/bash
# Builds audio-capture-helper and places the signed binary in bin/
set -e
cd "$(dirname "$0")"
echo "Building audio-capture-helper (macOS 15.0+, ScreenCaptureKit)..."
swift build -c release
codesign --entitlements AudioCaptureHelper.entitlements \
         -f -s - .build/release/AudioCaptureHelper
mkdir -p ../bin
cp .build/release/AudioCaptureHelper ../bin/audio-capture-helper
echo "Done → bin/audio-capture-helper"
echo ""
echo "On first use macOS will prompt for 'Screen & System Audio Recording' permission."
echo "Grant it in System Settings → Privacy & Security."
