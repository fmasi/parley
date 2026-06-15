#!/usr/bin/env python3
"""
Benchmark script: WhisperKit vs Python transcription pipeline.

Run with: python scripts/benchmark.py
Will prompt for sudo password (needed for powermetrics only).

Outputs to ~/Library/Application Support/Parley/benchmark/:
  report-YYYYMMDD-HHMMSS.txt     — human-readable summary
  telemetry-YYYYMMDD-HHMMSS/     — CSV time-series for graphing
    <label>-system.csv           — cpu_power_mw, gpu_power_mw, ane_power_mw
    <label>-process.csv          — cpu_pct, mem_mb, vsize_mb
    <label>-iostat.csv           — kb_per_transfer, transfers_per_sec, mb_per_sec
"""

import csv
import json
import os
import platform
import re
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

# ── Configuration ──

HOME = Path.home()
REPORT_DIR = HOME / "Library/Application Support/Parley" / "benchmark"
TIMESTAMP = datetime.now().strftime("%Y%m%d-%H%M%S")
REPORT_FILE = REPORT_DIR / f"report-{TIMESTAMP}.txt"
TELEMETRY_DIR = REPORT_DIR / f"telemetry-{TIMESTAMP}"

WHISPERKIT_BIN = Path(".build/debug/Parley")
PYTHON_BIN = sys.executable

BENCHMARKS = [
    {
        "name": "Jon Interview (38min)",
        "system": HOME / "Documents/Recordings/2026-04-01/152936-Jon Interview.wav",
        "mic": HOME / "Documents/Recordings/2026-04-01/152936-Jon Interview_mic.wav",
    },
    {
        "name": "Gustavo Part 2 (17min)",
        "system": HOME / "Documents/Recordings/2026-04-01/130007-gustavo part 2.wav",
        "mic": HOME / "Documents/Recordings/2026-04-01/130007-gustavo part 2_mic.wav",
    },
]


# ── Telemetry collectors ──

class PowerMetricsCollector(threading.Thread):
    """Collects CPU/GPU/ANE power via sudo powermetrics into CSV."""

    def __init__(self, csv_path: Path):
        super().__init__(daemon=True)
        self.csv_path = csv_path
        self.process = None
        self._stop_event = threading.Event()

    def run(self):
        start = time.time()
        with open(self.csv_path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["elapsed_s", "cpu_power_mw", "gpu_power_mw", "ane_power_mw"])

            cpu_mw = gpu_mw = ane_mw = 0
            try:
                self.process = subprocess.Popen(
                    ["sudo", "-n", "powermetrics",
                     "--samplers", "cpu_power,gpu_power,ane_power",
                     "-i", "2000"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                )
                for line in self.process.stdout:
                    if self._stop_event.is_set():
                        break
                    if "CPU Power" in line:
                        m = re.search(r"(\d+)", line)
                        if m:
                            cpu_mw = int(m.group(1))
                    elif "GPU Power" in line:
                        m = re.search(r"(\d+)", line)
                        if m:
                            gpu_mw = int(m.group(1))
                    elif "ANE Power" in line:
                        m = re.search(r"(\d+)", line)
                        if m:
                            ane_mw = int(m.group(1))
                        elapsed = int(time.time() - start)
                        writer.writerow([elapsed, cpu_mw, gpu_mw, ane_mw])
                        f.flush()
            except Exception:
                pass

    def stop(self):
        self._stop_event.set()
        if self.process:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()


class ProcessCollector(threading.Thread):
    """Collects per-process CPU% and memory via ps into CSV."""

    def __init__(self, csv_path: Path, process_pattern: str):
        super().__init__(daemon=True)
        self.csv_path = csv_path
        self.pattern = process_pattern
        self._stop_event = threading.Event()

    def run(self):
        start = time.time()
        with open(self.csv_path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["elapsed_s", "pid", "cpu_pct", "mem_mb", "vsize_mb"])

            while not self._stop_event.is_set():
                try:
                    result = subprocess.run(
                        ["pgrep", "-f", self.pattern],
                        capture_output=True, text=True, timeout=5,
                    )
                    pids = result.stdout.strip().split("\n")
                    for pid in pids:
                        if not pid:
                            continue
                        ps = subprocess.run(
                            ["ps", "-p", pid, "-o", "pid=,%cpu=,rss=,vsz="],
                            capture_output=True, text=True, timeout=5,
                        )
                        parts = ps.stdout.strip().split()
                        if len(parts) >= 4:
                            elapsed = int(time.time() - start)
                            mem_mb = int(parts[2]) // 1024
                            vsize_mb = int(parts[3]) // 1024
                            writer.writerow([elapsed, parts[0], parts[1], mem_mb, vsize_mb])
                            f.flush()
                except Exception:
                    pass
                self._stop_event.wait(2)

    def stop(self):
        self._stop_event.set()


class IOStatCollector(threading.Thread):
    """Collects disk I/O via iostat into CSV."""

    def __init__(self, csv_path: Path):
        super().__init__(daemon=True)
        self.csv_path = csv_path
        self.process = None
        self._stop_event = threading.Event()

    def run(self):
        start = time.time()
        with open(self.csv_path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["elapsed_s", "kb_per_transfer", "transfers_per_sec", "mb_per_sec"])

            try:
                self.process = subprocess.Popen(
                    ["iostat", "-w", "2"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                )
                for line in self.process.stdout:
                    if self._stop_event.is_set():
                        break
                    parts = line.split()
                    if len(parts) >= 3:
                        try:
                            kbt = float(parts[0])
                            tps = int(parts[1])
                            mbs = float(parts[2])
                            elapsed = int(time.time() - start)
                            writer.writerow([elapsed, kbt, tps, mbs])
                            f.flush()
                        except ValueError:
                            continue
            except Exception:
                pass

    def stop(self):
        self._stop_event.set()
        if self.process:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()


# ── CSV summary ──

def summarize_column(csv_path: Path, col_idx: int, name: str) -> str:
    """Summarize a CSV column: avg, min, max, samples."""
    try:
        with open(csv_path) as f:
            reader = csv.reader(f)
            next(reader)  # skip header
            values = []
            for row in reader:
                if len(row) > col_idx:
                    try:
                        values.append(float(row[col_idx]))
                    except ValueError:
                        continue
        if not values:
            return f"    {name}: no data"
        avg = sum(values) / len(values)
        return f"    {name}: avg={avg:.0f}, min={min(values):.0f}, max={max(values):.0f}, samples={len(values)}"
    except Exception:
        return f"    {name}: no data"


# ── Run a benchmark ──

def run_benchmark(
    name: str,
    label: str,
    cmd: list[str],
    output_file: Path,
    process_pattern: str,
    report_lines: list[str],
):
    print(f"\n─── {name} ───")
    print(f"  Command: {' '.join(str(c) for c in cmd)}")

    sys_csv = TELEMETRY_DIR / f"{label}-system.csv"
    proc_csv = TELEMETRY_DIR / f"{label}-process.csv"
    io_csv = TELEMETRY_DIR / f"{label}-iostat.csv"

    # Start telemetry
    power = PowerMetricsCollector(sys_csv)
    proc = ProcessCollector(proc_csv, process_pattern)
    io = IOStatCollector(io_csv)
    power.start()
    proc.start()
    io.start()
    print(f"  Telemetry started")

    # Run the command
    start = time.time()
    result = subprocess.run(cmd, capture_output=True, text=True)
    elapsed = time.time() - start
    minutes = int(elapsed) // 60
    seconds = int(elapsed) % 60

    # Stop telemetry
    power.stop()
    proc.stop()
    io.stop()
    power.join(timeout=5)
    proc.join(timeout=5)
    io.join(timeout=5)
    print(f"  Telemetry stopped")

    print(f"  Exit code: {result.returncode}")
    print(f"  Wall clock: {minutes}m {seconds}s ({int(elapsed)}s)")

    if result.returncode != 0 and result.stderr:
        print(f"  Stderr: {result.stderr[:200]}")

    # Count segments
    seg_count = "?"
    if output_file.exists() and result.returncode == 0:
        try:
            with open(output_file) as f:
                data = json.load(f)
            seg_count = len(data.get("segments", []))
            print(f"  Segments: {seg_count}")
        except Exception:
            pass

    # Summarize telemetry
    print("  System power:")
    s1 = summarize_column(sys_csv, 1, "CPU Power (mW)")
    s2 = summarize_column(sys_csv, 2, "GPU Power (mW)")
    s3 = summarize_column(sys_csv, 3, "ANE Power (mW)")
    print(s1)
    print(s2)
    print(s3)

    print("  Process:")
    s4 = summarize_column(proc_csv, 2, "CPU %")
    s5 = summarize_column(proc_csv, 3, "Memory (MB)")
    print(s4)
    print(s5)

    print("  Disk I/O:")
    s6 = summarize_column(io_csv, 2, "Transfers/sec")
    s7 = summarize_column(io_csv, 3, "MB/sec")
    print(s6)
    print(s7)

    # Data point counts
    def count_rows(p):
        try:
            return sum(1 for _ in open(p)) - 1
        except Exception:
            return 0

    sys_n = count_rows(sys_csv)
    proc_n = count_rows(proc_csv)
    io_n = count_rows(io_csv)
    print(f"  Data points: system={sys_n}, process={proc_n}, io={io_n}")

    # Append to report
    report_lines.append(f"\n─── {name} ───")
    report_lines.append(f"Wall clock: {minutes}m {seconds}s ({int(elapsed)}s)")
    report_lines.append(f"Segments: {seg_count}")
    report_lines.append(f"Exit code: {result.returncode}")
    report_lines.append(f"\nSystem power:\n{s1}\n{s2}\n{s3}")
    report_lines.append(f"\nProcess:\n{s4}\n{s5}")
    report_lines.append(f"\nDisk I/O:\n{s6}\n{s7}")
    report_lines.append(f"\nCSV: {sys_csv.name}, {proc_csv.name}, {io_csv.name}")


# ── Main ──

def main():
    print("╔═══════════════════════════════════════════╗")
    print("║  Transcription Pipeline Benchmark         ║")
    print("╚═══════════════════════════════════════════╝")

    # Pre-auth sudo
    print("\nAuthenticating sudo for powermetrics...")
    r = subprocess.run(["sudo", "-v"])
    if r.returncode != 0:
        print("ERROR: sudo required for powermetrics")
        sys.exit(1)

    # Keep sudo alive
    def sudo_keepalive():
        while True:
            subprocess.run(["sudo", "-n", "true"], capture_output=True)
            time.sleep(240)

    keepalive = threading.Thread(target=sudo_keepalive, daemon=True)
    keepalive.start()

    # Setup dirs
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    TELEMETRY_DIR.mkdir(parents=True, exist_ok=True)

    # Validate audio files
    for b in BENCHMARKS:
        for key in ("system", "mic"):
            if not b[key].exists():
                print(f"ERROR: Audio file not found: {b[key]}")
                sys.exit(1)

    # Build if needed
    if not WHISPERKIT_BIN.exists():
        print("Building WhisperKit binary...")
        subprocess.run(["swift", "build"], check=True)

    # Extract Python transcribe.py from main
    python_script = Path("/tmp/benchmark-transcribe.py")
    r = subprocess.run(
        ["git", "show", "main:transcribe.py"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        print("ERROR: Cannot extract transcribe.py from main branch")
        sys.exit(1)
    python_script.write_text(r.stdout)

    # Machine info
    try:
        cpu = subprocess.run(
            ["sysctl", "-n", "machdep.cpu.brand_string"],
            capture_output=True, text=True,
        ).stdout.strip()
    except Exception:
        cpu = "Apple Silicon"
    try:
        mem_bytes = int(subprocess.run(
            ["sysctl", "-n", "hw.memsize"],
            capture_output=True, text=True,
        ).stdout.strip())
        mem_gb = f"{mem_bytes / (1024**3):.0f}GB"
    except Exception:
        mem_gb = "?"
    macos_ver = platform.mac_ver()[0]

    report = [
        "Transcription Pipeline Benchmark",
        "================================",
        f"Date: {datetime.now()}",
        f"Machine: {cpu}",
        f"Memory: {mem_gb}",
        f"macOS: {macos_ver}",
        "",
    ]
    for b in BENCHMARKS:
        sz_sys = b["system"].stat().st_size / (1024 * 1024)
        sz_mic = b["mic"].stat().st_size / (1024 * 1024)
        report.append(f"  {b['name']}: system={sz_sys:.0f}MB, mic={sz_mic:.0f}MB")
    report.append("")
    report.append("Telemetry sampling: 2s intervals, all CSV with elapsed_s column")
    report.append("")

    print(f"\nReport: {REPORT_FILE}")
    print(f"Telemetry: {TELEMETRY_DIR}/")

    # ── WhisperKit benchmarks ──
    print("\n══════ WhisperKit (large-v3-turbo, CoreML) ══════")
    report.append("═══════════════════════════════════════════")
    report.append("WhisperKit (large-v3-turbo, CoreML)")
    report.append("═══════════════════════════════════════════")

    for i, b in enumerate(BENCHMARKS):
        out = Path(f"/tmp/bench-wk-{i}.json")
        run_benchmark(
            name=f"{b['name']} — WhisperKit",
            label=f"whisperkit-{i}",
            cmd=[
                str(WHISPERKIT_BIN), "transcribe",
                "-i", str(b["system"]),
                "-i", str(b["mic"]),
                "-f", "json",
                "-o", str(out),
                "--no-diarize",
            ],
            output_file=out,
            process_pattern="Parley transcribe",
            report_lines=report,
        )

    # ── Python benchmarks ──
    print("\n══════ Python (mlx-whisper, large-v3, MLX GPU) ══════")
    report.append("")
    report.append("═══════════════════════════════════════════")
    report.append("Python (mlx-whisper, large-v3, MLX GPU)")
    report.append("═══════════════════════════════════════════")

    conda = os.environ.get("CONDA_PREFIX", "")
    if not conda:
        print("WARNING: No conda env active. Python benchmarks may fail.")

    for i, b in enumerate(BENCHMARKS):
        out = Path(f"/tmp/bench-py-{i}.json")
        run_benchmark(
            name=f"{b['name']} — Python",
            label=f"python-{i}",
            cmd=[
                PYTHON_BIN, str(python_script),
                "-i", str(b["system"]),
                "-i", str(b["mic"]),
                "-f", "json",
                "-o", str(out),
                "--no-diarize",
            ],
            output_file=out,
            process_pattern="transcribe.py",
            report_lines=report,
        )

    # ── Write report ──
    report.append("")
    report.append("═══════════════════════════════════════════")
    report.append("Graphing")
    report.append("═══════════════════════════════════════════")
    report.append("")
    report.append("All CSVs have elapsed_s as first column. Import into any charting tool.")
    report.append("")
    report.append("Suggested graphs:")
    report.append("  1. CPU/GPU/ANE power over time — which hardware is active?")
    report.append("  2. Process CPU% over time — how hard is the process working?")
    report.append("  3. Process memory over time — model load footprint")
    report.append("  4. Disk I/O — is audio loading a bottleneck?")
    report.append("")
    report.append("Compare WhisperKit vs Python side-by-side.")

    REPORT_FILE.write_text("\n".join(report))

    # Cleanup
    python_script.unlink(missing_ok=True)

    print("\n══════ Complete ══════")
    print(f"\nReport: {REPORT_FILE}")
    print(f"Telemetry: {TELEMETRY_DIR}/")
    print(f"\nFiles:")
    for f in sorted(TELEMETRY_DIR.iterdir()):
        sz = f.stat().st_size
        print(f"  {f.name} ({sz} bytes)")


if __name__ == "__main__":
    main()
