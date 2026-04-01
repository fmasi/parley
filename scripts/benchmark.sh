#!/bin/bash
# Benchmark script: WhisperKit vs Python transcription pipeline
# Run with: sudo bash scripts/benchmark.sh
# Requires: sudo (for powermetrics), conda env transcribe-bundle (for Python baseline)
#
# Outputs:
#   ~/.audio-transcribe/benchmark/
#     report-YYYYMMDD-HHMMSS.txt          — human-readable summary
#     telemetry-YYYYMMDD-HHMMSS/
#       <label>-system.csv                — time-series: cpu_power,gpu_power,ane_power (mW)
#       <label>-process.csv               — time-series: cpu%,mem_mb,rss_kb
#       <label>-iostat.csv                — time-series: KB/t,tps,MB/s
#
# All CSVs have a timestamp column for graphing.

set -e

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_DIR="$HOME/.audio-transcribe/benchmark"
REPORT="$REPORT_DIR/report-${TIMESTAMP}.txt"
TELEMETRY_DIR="$REPORT_DIR/telemetry-${TIMESTAMP}"

# Audio files to benchmark (edit these paths)
AUDIO_1_SYSTEM="$HOME/Documents/Recordings/2026-04-01/152936-Jon Interview.wav"
AUDIO_1_MIC="$HOME/Documents/Recordings/2026-04-01/152936-Jon Interview_mic.wav"
AUDIO_1_NAME="Jon Interview (38min)"

AUDIO_2_SYSTEM="$HOME/Documents/Recordings/2026-04-01/130007-gustavo part 2.wav"
AUDIO_2_MIC="$HOME/Documents/Recordings/2026-04-01/130007-gustavo part 2_mic.wav"
AUDIO_2_NAME="Gustavo Part 2 (17min)"

WHISPERKIT_BIN=".build/debug/AudioTranscribe"
PYTHON_SCRIPT="/tmp/benchmark-transcribe.py"
PYTHON_BIN="python"

mkdir -p "$REPORT_DIR" "$TELEMETRY_DIR"

# Extract transcribe.py from main branch for Python baseline
git show main:transcribe.py > "$PYTHON_SCRIPT" 2>/dev/null || {
    echo "ERROR: Cannot extract transcribe.py from main branch"
    exit 1
}

# Build WhisperKit binary if needed
if [ ! -f "$WHISPERKIT_BIN" ]; then
    echo "Building WhisperKit binary..."
    swift build
fi

# ──────────────────────────────────────────────
# Telemetry collection — all CSV for graphing
# ──────────────────────────────────────────────

start_telemetry() {
    local label="$1"
    local sys_csv="$TELEMETRY_DIR/${label}-system.csv"
    local proc_csv="$TELEMETRY_DIR/${label}-process.csv"
    local io_csv="$TELEMETRY_DIR/${label}-iostat.csv"

    # ── System-level: CPU/GPU/ANE power via powermetrics ──
    # Parse powermetrics output into CSV in real-time
    echo "elapsed_s,cpu_power_mw,gpu_power_mw,ane_power_mw,cpu_freq_mhz" > "$sys_csv"
    (
        local start_epoch
        start_epoch=$(date +%s)
        powermetrics \
            --samplers cpu_power,gpu_power,ane_power \
            -i 2000 2>/dev/null | while IFS= read -r line; do
            # Parse power lines as they appear
            case "$line" in
                *"CPU Power"*)
                    CPU_MW=$(echo "$line" | grep -oE '[0-9]+' | head -1)
                    ;;
                *"GPU Power"*)
                    GPU_MW=$(echo "$line" | grep -oE '[0-9]+' | head -1)
                    ;;
                *"ANE Power"*)
                    ANE_MW=$(echo "$line" | grep -oE '[0-9]+' | head -1)
                    # ANE is usually the last power line in a sample — emit row
                    local now
                    now=$(date +%s)
                    local elapsed=$((now - start_epoch))
                    echo "${elapsed},${CPU_MW:-0},${GPU_MW:-0},${ANE_MW:-0},0" >> "$sys_csv"
                    ;;
                *"E-Cluster HW active frequency"*|*"P-Cluster HW active frequency"*)
                    CPU_FREQ=$(echo "$line" | grep -oE '[0-9]+' | head -1)
                    ;;
            esac
        done
    ) &
    POWER_PID=$!

    # ── Process-level: CPU%, memory, threads ──
    echo "elapsed_s,pid,cpu_pct,mem_mb,vsize_mb" > "$proc_csv"
    (
        local start_epoch
        start_epoch=$(date +%s)
        while true; do
            local pid
            pid=$(pgrep -f "AudioTranscribe transcribe" 2>/dev/null || pgrep -f "transcribe.py" 2>/dev/null || echo "")
            if [ -n "$pid" ]; then
                # macOS ps: pid, %cpu, rss (KB), vsz (KB)
                local stats
                stats=$(ps -p "$pid" -o pid=,%cpu=,rss=,vsz= 2>/dev/null | tail -1 | xargs)
                if [ -n "$stats" ]; then
                    local p cpu rss vsz
                    p=$(echo "$stats" | awk '{print $1}')
                    cpu=$(echo "$stats" | awk '{print $2}')
                    rss=$(echo "$stats" | awk '{print $3}')
                    vsz=$(echo "$stats" | awk '{print $4}')
                    local mem_mb=$((rss / 1024))
                    local vsize_mb=$((vsz / 1024))
                    local now
                    now=$(date +%s)
                    local elapsed=$((now - start_epoch))
                    echo "${elapsed},${p},${cpu},${mem_mb},${vsize_mb}" >> "$proc_csv"
                fi
            fi
            sleep 2
        done
    ) &
    PROC_PID=$!

    # ── Disk I/O ──
    echo "elapsed_s,kb_per_transfer,transfers_per_sec,mb_per_sec" > "$io_csv"
    (
        local start_epoch
        start_epoch=$(date +%s)
        # Skip the header lines, parse data lines
        iostat -w 2 2>/dev/null | while IFS= read -r line; do
            # iostat data lines have numbers; skip headers
            local kbt tps mbs
            kbt=$(echo "$line" | awk '{print $1}' | grep -E '^[0-9]' || true)
            if [ -n "$kbt" ]; then
                tps=$(echo "$line" | awk '{print $2}')
                mbs=$(echo "$line" | awk '{print $3}')
                local now
                now=$(date +%s)
                local elapsed=$((now - start_epoch))
                echo "${elapsed},${kbt},${tps},${mbs}" >> "$io_csv"
            fi
        done
    ) &
    IO_PID=$!

    echo "  Telemetry started (power=$POWER_PID, process=$PROC_PID, io=$IO_PID)"
}

stop_telemetry() {
    kill $POWER_PID $PROC_PID $IO_PID 2>/dev/null
    wait $POWER_PID $PROC_PID $IO_PID 2>/dev/null
    echo "  Telemetry stopped"
}

# ──────────────────────────────────────────────
# CSV summary helpers
# ──────────────────────────────────────────────

summarize_csv() {
    local file="$1"
    local col="$2"  # 1-indexed column number
    local name="$3"

    if [ ! -f "$file" ] || [ "$(wc -l < "$file")" -le 1 ]; then
        echo "    $name: no data"
        return
    fi

    local stats
    stats=$(tail -n +2 "$file" | cut -d',' -f"$col" | awk '
        NR==1 { min=$1; max=$1; sum=$1; n=1; next }
        { if($1<min) min=$1; if($1>max) max=$1; sum+=$1; n++ }
        END { if(n>0) printf "avg=%.0f, min=%.0f, max=%.0f, samples=%d", sum/n, min, max, n; else print "no data" }
    ')
    echo "    $name: $stats"
}

# ──────────────────────────────────────────────
# Run a single benchmark
# ──────────────────────────────────────────────

run_benchmark() {
    local name="$1"
    local label="$2"
    local cmd="$3"
    local output_file="$4"

    echo ""
    echo "─── $name ───"
    echo "  Command: $cmd"

    start_telemetry "$label"

    local start_time
    start_time=$(date +%s)

    eval "$cmd" > /dev/null 2>&1
    local exit_code=$?

    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    local minutes=$((elapsed / 60))
    local seconds=$((elapsed % 60))

    stop_telemetry

    echo "  Exit code: $exit_code"
    echo "  Wall clock: ${minutes}m ${seconds}s (${elapsed}s)"

    # Count segments in output
    local seg_count="?"
    if [ -f "$output_file" ] && [ $exit_code -eq 0 ]; then
        seg_count=$($PYTHON_BIN -c "import json; d=json.load(open('$output_file')); print(len(d['segments']))" 2>/dev/null || echo "?")
        echo "  Segments: $seg_count"
    fi

    # Summarize from CSVs
    echo "  System power:"
    summarize_csv "$TELEMETRY_DIR/${label}-system.csv" 2 "CPU Power (mW)"
    summarize_csv "$TELEMETRY_DIR/${label}-system.csv" 3 "GPU Power (mW)"
    summarize_csv "$TELEMETRY_DIR/${label}-system.csv" 4 "ANE Power (mW)"

    echo "  Process:"
    summarize_csv "$TELEMETRY_DIR/${label}-process.csv" 3 "CPU %"
    summarize_csv "$TELEMETRY_DIR/${label}-process.csv" 4 "Memory (MB)"

    echo "  Disk I/O:"
    summarize_csv "$TELEMETRY_DIR/${label}-iostat.csv" 3 "Transfers/sec"
    summarize_csv "$TELEMETRY_DIR/${label}-iostat.csv" 4 "MB/sec"

    # Data point counts for verification
    local sys_points proc_points io_points
    sys_points=$(( $(wc -l < "$TELEMETRY_DIR/${label}-system.csv") - 1 ))
    proc_points=$(( $(wc -l < "$TELEMETRY_DIR/${label}-process.csv") - 1 ))
    io_points=$(( $(wc -l < "$TELEMETRY_DIR/${label}-iostat.csv") - 1 ))
    echo "  Data points: system=${sys_points}, process=${proc_points}, io=${io_points}"

    # Write to report
    {
        echo ""
        echo "─── $name ───"
        echo "Wall clock: ${minutes}m ${seconds}s (${elapsed}s)"
        echo "Segments: ${seg_count}"
        echo "Exit code: $exit_code"
        echo ""
        echo "System power:"
        summarize_csv "$TELEMETRY_DIR/${label}-system.csv" 2 "CPU Power (mW)"
        summarize_csv "$TELEMETRY_DIR/${label}-system.csv" 3 "GPU Power (mW)"
        summarize_csv "$TELEMETRY_DIR/${label}-system.csv" 4 "ANE Power (mW)"
        echo ""
        echo "Process:"
        summarize_csv "$TELEMETRY_DIR/${label}-process.csv" 3 "CPU %"
        summarize_csv "$TELEMETRY_DIR/${label}-process.csv" 4 "Memory (MB)"
        echo ""
        echo "Disk I/O:"
        summarize_csv "$TELEMETRY_DIR/${label}-iostat.csv" 3 "Transfers/sec"
        summarize_csv "$TELEMETRY_DIR/${label}-iostat.csv" 4 "MB/sec"
        echo ""
        echo "CSV files:"
        echo "  $TELEMETRY_DIR/${label}-system.csv"
        echo "  $TELEMETRY_DIR/${label}-process.csv"
        echo "  $TELEMETRY_DIR/${label}-iostat.csv"
    } >> "$REPORT"
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────

echo "╔═══════════════════════════════════════════╗"
echo "║  Transcription Pipeline Benchmark         ║"
echo "╚═══════════════════════════════════════════╝"
echo ""
echo "Report: $REPORT"
echo "Telemetry: $TELEMETRY_DIR/"

{
    echo "Transcription Pipeline Benchmark"
    echo "================================"
    echo "Date: $(date)"
    echo "Machine: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')"
    echo "Memory: $(sysctl -n hw.memsize | awk '{printf "%.0fGB", $1/1073741824}')"
    echo "macOS: $(sw_vers -productVersion)"
    echo ""
    echo "Audio files:"
    echo "  1. $AUDIO_1_NAME"
    echo "     System: $(du -h "$AUDIO_1_SYSTEM" | cut -f1)"
    echo "     Mic: $(du -h "$AUDIO_1_MIC" | cut -f1)"
    echo "  2. $AUDIO_2_NAME"
    echo "     System: $(du -h "$AUDIO_2_SYSTEM" | cut -f1)"
    echo "     Mic: $(du -h "$AUDIO_2_MIC" | cut -f1)"
    echo ""
    echo "Telemetry sampling: system=2s, process=2s, io=2s"
    echo "All time-series saved as CSV for graphing."
    echo ""
} > "$REPORT"

# ── WhisperKit benchmarks ──
echo ""
echo "══════ WhisperKit (large-v3-turbo, CoreML) ══════"
{
    echo "═══════════════════════════════════════════"
    echo "WhisperKit (large-v3-turbo, CoreML)"
    echo "═══════════════════════════════════════════"
} >> "$REPORT"

run_benchmark \
    "$AUDIO_1_NAME — WhisperKit" \
    "whisperkit-jon" \
    "$WHISPERKIT_BIN transcribe -i \"$AUDIO_1_SYSTEM\" -i \"$AUDIO_1_MIC\" -f json -o /tmp/bench-wk-jon.json --no-diarize" \
    "/tmp/bench-wk-jon.json"

run_benchmark \
    "$AUDIO_2_NAME — WhisperKit" \
    "whisperkit-gustavo" \
    "$WHISPERKIT_BIN transcribe -i \"$AUDIO_2_SYSTEM\" -i \"$AUDIO_2_MIC\" -f json -o /tmp/bench-wk-gustavo.json --no-diarize" \
    "/tmp/bench-wk-gustavo.json"

# ── Python (mlx-whisper) benchmarks ──
echo ""
echo "══════ Python (mlx-whisper, large-v3, MLX GPU) ══════"
{
    echo ""
    echo "═══════════════════════════════════════════"
    echo "Python (mlx-whisper, large-v3, MLX GPU)"
    echo "═══════════════════════════════════════════"
} >> "$REPORT"

# Check conda env
if [ -z "$CONDA_PREFIX" ]; then
    echo "WARNING: No conda env active. Python benchmarks may fail."
    echo "  Run: conda activate transcribe-bundle"
fi

run_benchmark \
    "$AUDIO_1_NAME — Python" \
    "python-jon" \
    "$PYTHON_BIN $PYTHON_SCRIPT -i \"$AUDIO_1_SYSTEM\" -i \"$AUDIO_1_MIC\" -f json -o /tmp/bench-py-jon.json --no-diarize" \
    "/tmp/bench-py-jon.json"

run_benchmark \
    "$AUDIO_2_NAME — Python" \
    "python-gustavo" \
    "$PYTHON_BIN $PYTHON_SCRIPT -i \"$AUDIO_2_SYSTEM\" -i \"$AUDIO_2_MIC\" -f json -o /tmp/bench-py-gustavo.json --no-diarize" \
    "/tmp/bench-py-gustavo.json"

# ── Final summary ──
{
    echo ""
    echo "═══════════════════════════════════════════"
    echo "Graphing"
    echo "═══════════════════════════════════════════"
    echo ""
    echo "All telemetry is in CSV format with elapsed_s as the first column."
    echo "Import into any charting tool (Excel, Google Sheets, Python matplotlib)."
    echo ""
    echo "Suggested graphs:"
    echo "  1. CPU/GPU/ANE power over time (system CSV, columns 2-4)"
    echo "     → Shows which hardware is active during transcription"
    echo "  2. Process CPU% over time (process CSV, column 3)"
    echo "     → Shows how much CPU the transcription process uses"
    echo "  3. Process memory over time (process CSV, column 4)"
    echo "     → Shows memory footprint during model load + inference"
    echo "  4. Disk I/O over time (iostat CSV, columns 3-4)"
    echo "     → Shows if disk is a bottleneck (audio loading, model loading)"
    echo ""
    echo "Compare WhisperKit vs Python CSVs side-by-side to see"
    echo "which hardware each pipeline actually uses."
} >> "$REPORT"

echo ""
echo "══════ Complete ══════"
echo ""
echo "Report: $REPORT"
echo "Telemetry CSVs: $TELEMETRY_DIR/"
echo ""
echo "Files created:"
ls -lh "$TELEMETRY_DIR/"
echo ""
echo "To view report: cat $REPORT"

# Cleanup
rm -f "$PYTHON_SCRIPT"
