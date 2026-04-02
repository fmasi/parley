#!/usr/bin/env python3
"""Developer iteration tool for AudioTranscribe.

Build, install, and launch the app for manual testing.

Default (no flags): kill -> build -> install -> launch + print checklist.
Step flags (--kill, --build, --install, --launch, --reset-tcc) switch to explicit mode.
Modifier flags (--debug) layer on top of default or explicit steps.

Examples:
    python scripts/dev.py                          # full cycle
    python scripts/dev.py --debug                  # full cycle + tail unified log
    python scripts/dev.py --reset-tcc              # just reset TCC permissions
    python scripts/dev.py --reset-tcc --launch     # reset + launch
    python scripts/dev.py --build --install        # build + install only
    python scripts/dev.py --kill --launch          # relaunch existing install
"""

import argparse
import subprocess
import sys
import time
from pathlib import Path

BUNDLE_ID = "com.audio-transcribe.app"
APP_PATH = Path("/Applications/AudioTranscribe.app")
BINARY_PATH = APP_PATH / "Contents" / "MacOS" / "AudioTranscribe"

PROJECT_ROOT = Path(__file__).resolve().parent.parent
PACKAGE_SCRIPT = PROJECT_ROOT / "package_app.sh"
CHECKLIST_FILE = Path(__file__).resolve().parent / "test-checklist.md"

# Step flags
STEP_FLAGS = ("kill", "build", "install", "launch", "reset_tcc")

DEFAULT_STEPS = {"kill", "build", "install", "launch"}
TCC_SERVICES = ["Microphone", "ScreenCapture", "Calendar"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Developer iteration tool for AudioTranscribe.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    steps = parser.add_argument_group("steps (explicit mode — only selected steps run)")
    steps.add_argument("--kill", action="store_true", help="Kill running AudioTranscribe")
    steps.add_argument("--build", action="store_true", help="Build app bundle")
    steps.add_argument("--install", action="store_true", help="Install to /Applications")
    steps.add_argument("--launch", action="store_true", help="Launch via open")
    steps.add_argument("--reset-tcc", action="store_true", help="Reset TCC permissions")

    mods = parser.add_argument_group("modifiers (layer on top of default or explicit)")
    mods.add_argument("--debug", action="store_true",
                      help="Launch app normally, then tail unified log (Ctrl+C to stop)")

    return parser.parse_args()


def resolve_steps(args: argparse.Namespace) -> set[str]:
    """Determine which steps to run based on flags."""
    explicit = {f for f in STEP_FLAGS if getattr(args, f)}

    if explicit:
        steps = explicit
    else:
        steps = set(DEFAULT_STEPS)

    # Modifier: --debug adds log tailing after launch
    if args.debug:
        steps.add("debug")

    return steps


def step(name: str) -> None:
    """Print a step header."""
    print(f"\033[1;36m==> {name}\033[0m")


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    """Run a subprocess, exiting on failure."""
    result = subprocess.run(cmd, **kwargs)
    if result.returncode != 0:
        print(f"\033[1;31mFailed: {' '.join(cmd)}\033[0m", file=sys.stderr)
        sys.exit(result.returncode)
    return result


def do_kill() -> None:
    step("Killing AudioTranscribe if running")
    subprocess.run(["pkill", "-x", "AudioTranscribe"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)


def do_reset_tcc() -> None:
    step("Resetting TCC permissions")
    for service in TCC_SERVICES:
        result = subprocess.run(["tccutil", "reset", service, BUNDLE_ID],
                                capture_output=True, text=True)
        output = (result.stdout + result.stderr).strip()
        if output:
            for line in output.splitlines():
                print(f"   {line}")
        else:
            print(f"   Reset {service}")
    print("   Note: Notifications can't be reset via tccutil.")
    print("   To reset: System Settings > Notifications > AudioTranscribe")


def do_build(install: bool) -> None:
    label = "Building"
    if install:
        label += " + installing"
    step(label)

    cmd = ["bash", str(PACKAGE_SCRIPT)]
    if install:
        cmd.append("--install")

    run(cmd, cwd=PROJECT_ROOT)


def do_launch() -> None:
    step("Launching AudioTranscribe")
    run(["open", str(APP_PATH)])


def do_debug() -> None:
    step("Tailing unified log (Ctrl+C to stop)")
    print(f"   Subsystem: {BUNDLE_ID}")
    print(f"   Level: debug\n")
    try:
        subprocess.run([
            "log", "stream",
            "--predicate", f'subsystem == "{BUNDLE_ID}"',
            "--level", "debug",
            "--style", "compact",
        ])
    except KeyboardInterrupt:
        print("\n   Log stream stopped.")


def print_checklist() -> None:
    if not CHECKLIST_FILE.exists():
        return

    print()
    print("\033[1;33m" + "=" * 50 + "\033[0m")
    print(CHECKLIST_FILE.read_text().rstrip())
    print("\033[1;33m" + "=" * 50 + "\033[0m")


def main() -> None:
    args = parse_args()
    steps = resolve_steps(args)

    # Fixed execution order
    if "kill" in steps:
        do_kill()
    if "reset_tcc" in steps:
        do_reset_tcc()
    if "build" in steps:
        # Fresh build = new ad-hoc signature, so TCC must be reset
        if "reset_tcc" not in steps:
            do_reset_tcc()
        do_build(install="install" in steps)
    elif "install" in steps:
        # Install without build — delegate to package_app.sh --install
        do_build(install=True)
    if "launch" in steps:
        do_launch()
        print_checklist()
    if "debug" in steps:
        do_debug()  # blocking — runs after launch


if __name__ == "__main__":
    main()
