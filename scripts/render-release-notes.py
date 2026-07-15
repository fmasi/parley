#!/usr/bin/env python3
"""CLI entry for the release-notes renderer. See render_release_notes.py for the implementation."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render_release_notes import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main(sys.argv))
