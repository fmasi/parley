# Developer Iteration Script (`scripts/dev.py`)

## Goal

Replace the bash `test-fresh.sh` with a Python CLI that builds, installs, and launches the app for manual testing. Modular flags, sensible defaults, dynamic test checklist.

## CLI Design

### Default (no flags): full cycle

```
python scripts/dev.py
```

Runs: kill → build → install → launch (via `open`) → print checklist

### Step flags — opt into explicit mode

When any step flag is present, only those steps run:

| Flag | Step |
|------|------|
| `--kill` | Kill running AudioTranscribe |
| `--build` | Build app bundle (swift build + package_app.sh) |
| `--install` | Install to /Applications |
| `--launch` | Launch via `open` |

Examples:
- `--build` → build only
- `--build --install` → build + install
- `--kill --launch` → kill + relaunch existing

### Modifier flags — layer on top of default or explicit

| Flag | Effect |
|------|--------|
| `--console` | Replace `--launch` with direct binary execution (stderr visible in terminal) |
| `--reset-tcc` | Reset TCC permissions (implies `--kill`) |
| `--skip-embed` | Skip Python embedding in build step (faster) |

Examples:
- `dev.py --reset-tcc` → kill → reset → build → install → launch (full default + reset)
- `dev.py --console` → kill → build → install → console (full default, console mode)
- `dev.py --reset-tcc --build` → kill → reset → build (explicit steps + modifier)

### Execution order

Always: kill → reset-tcc → build → install → launch/console → checklist

Steps not selected are skipped. Order is fixed regardless of flag order on CLI.

### Preflight

- Conda env check: only when `--build` is active
- Bundle exists check: only when `--launch`/`--console` without `--build --install`

### Test checklist

Lives in `scripts/test-checklist.md`. Printed at end of any run that includes launch/console. I (Claude) update this file each session with the relevant test scenarios.

Format: plain markdown, numbered items, grouped by feature area.

## Files

| Action | Path |
|--------|------|
| Create | `scripts/dev.py` |
| Create | `scripts/test-checklist.md` |
| Delete | `scripts/test-fresh.sh` |

## Not in scope

- Automated test execution (this is for manual testing)
- Watch mode / file monitoring
- README updates (separate task)
