#!/usr/bin/env bash
# embed_python.sh — Embeds the relocatable conda Python environment into the
# Xcode build output so the app can launch transcribe.py.
#
# Usage: bash packaging/embed_python.sh [BUILD_DIR]
#   BUILD_DIR defaults to .build/debug (SPM) or the Xcode DerivedData path.
#
# Run once after cloning, or whenever Python dependencies change.

set -euo pipefail

CONDA_ENV="${CONDA_PREFIX:?Error: activate your conda environment first}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Determine build output directory
BUILD_DIR="${1:-.build/debug}"
RESOURCES_DIR="${BUILD_DIR}/AudioTranscribe.app/Contents/Resources"

echo "==> Embedding Python from: $CONDA_ENV"
echo "==> Into: $RESOURCES_DIR"

mkdir -p "$RESOURCES_DIR"

# 1. Copy relocatable Python framework
echo "  Copying Python framework..."
mkdir -p "$RESOURCES_DIR/python"
rsync -a --delete \
    "$CONDA_ENV/" \
    "$RESOURCES_DIR/python/" \
    --exclude='*.pyc' \
    --exclude='__pycache__' \
    --exclude='pip*' \
    --exclude='setuptools*'

# 2. Copy Python application scripts
echo "  Copying Python scripts..."
mkdir -p "$RESOURCES_DIR/Python/service"
cp "$PROJECT_ROOT/transcribe.py" "$RESOURCES_DIR/Python/"
cp "$PROJECT_ROOT/rename_speakers.py" "$RESOURCES_DIR/Python/"
cp "$PROJECT_ROOT/service/config_manager.py" "$RESOURCES_DIR/Python/service/"
cp "$PROJECT_ROOT/service/logger.py" "$RESOURCES_DIR/Python/service/"
# Copy __init__.py if it exists
[ -f "$PROJECT_ROOT/service/__init__.py" ] && \
    cp "$PROJECT_ROOT/service/__init__.py" "$RESOURCES_DIR/Python/service/"

echo "==> Done. Python embedded successfully."
