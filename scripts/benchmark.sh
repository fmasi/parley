#!/bin/bash
# Benchmark script: WhisperKit vs Python transcription pipeline
# Run with: sudo bash scripts/benchmark.sh
# Requires: sudo (for powermetrics), conda env transcribe-bundle (for Python baseline)

set -e

REPORT_DIR="$HOME/.audio-transcribe/benchmark"
REPORT="$REPORT_DIR/report-$(date +%Y%m%d-%H%M%S).txt"
TELEMETRY_DIR="$REPORT_DIR/telemetry-$(date +%Y%m%d-%H%M%S)"

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
# Telemetry functions
# ──────────────────────────────────────────────

start_telemetry() {
    local label="$1"
    local telem_file="$TELEMETRY_DIR/${label}"

    # powermetrics: GPU, ANE, CPU power (sampled every 5s)
    powermetrics \
        --samplers cpu_power,gpu_power,ane_power \
        -i 5000 \
        --show-process-energy \
        > "${telem_file}-powermetrics.txt" 2>&1 &
    POWERMETRICS_PID=$!

    # iostat: disk I/O (sampled every 5s)
    iostat -w 5 > "${telem_file}-iostat.txt" 2>&1 &
    IOSTAT_PID=$!

    # Process-level CPU/memory sampling (every 2s)
    (
        echo "timestamp,pid,cpu,mem_mb,threads" > "${telem_file}-process.csv"
        while true; do
            # Find the transcription process
            local pid
            pid=$(pgrep -f "AudioTranscribe transcribe" 2>/dev/null || pgrep -f "transcribe.py" 2>/dev/null || echo "")
            if [ -n "$pid" ]; then
                local stats
                stats=$(ps -p "$pid" -o pid=,%cpu=,rss=,nlwp= 2>/dev/null | tail -1)
                if [ -n "$stats" ]; then
                    local cpu mem_kb threads
                    cpu=$(echo "$stats" | awk '{print $2}')
                    mem_kb=$(echo "$stats" | awk '{print $3}')
                    threads=$(echo "$stats" | awk '{print $4}')
                    local mem_mb=$((mem_kb / 1024))
                    echo "$(date +%H:%M:%S),$pid,$cpu,$mem_mb,$threads" >> "${telem_file}-process.csv"
                fi
            fi
            sleep 2
        done
    ) &
    PROCESS_PID=$!

    echo "  Telemetry started (powermetrics=$POWERMETRICS_PID, iostat=$IOSTAT_PID, process=$PROCESS_PID)"
}

stop_telemetry() {
    kill $POWERMETRICS_PID $IOSTAT_PID $PROCESS_PID 2>/dev/null
    wait $POWERMETRICS_PID $IOSTAT_PID $PROCESS_PID 2>/dev/null
    echo "  Telemetry stopped"
}

# ──────────────────────────────────────────────
# Summarize powermetrics
# ──────────────────────────────────────────────

summarize_power() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "  (no powermetrics data)"
        return
    fi

    echo "  Hardware utilization (from powermetrics):"

    # ANE power
    local ane_lines
    ane_lines=$(grep -i "ANE Power" "$file" 2>/dev/null | grep -oE '[0-9]+' | head -20)
    if [ -n "$ane_lines" ]; then
        local ane_avg
        ane_avg=$(echo "$ane_lines" | awk '{s+=$1; n++} END {if(n>0) printf "%.0f", s/n; else print "0"}')
        echo "    ANE Power (avg): ${ane_avg} mW"
    else
        echo "    ANE Power: no data (ANE may not be active)"
    fi

    # GPU power
    local gpu_lines
    gpu_lines=$(grep -i "GPU Power" "$file" 2>/dev/null | grep -oE '[0-9]+' | head -20)
    if [ -n "$gpu_lines" ]; then
        local gpu_avg
        gpu_avg=$(echo "$gpu_lines" | awk '{s+=$1; n++} END {if(n>0) printf "%.0f", s/n; else print "0"}')
        echo "    GPU Power (avg): ${gpu_avg} mW"
    else
        echo "    GPU Power: no data"
    fi

    # CPU power
    local cpu_lines
    cpu_lines=$(grep -i "CPU Power" "$file" 2>/dev/null | grep -oE '[0-9]+' | head -20)
    if [ -n "$cpu_lines" ]; then
        local cpu_avg
        cpu_avg=$(echo "$cpu_lines" | awk '{s+=$1; n++} END {if(n>0) printf "%.0f", s/n; else print "0"}')
        echo "    CPU Power (avg): ${cpu_avg} mW"
    else
        echo "    CPU Power: no data"
    fi
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
    if [ -f "$output_file" ] && [ $exit_code -eq 0 ]; then
        local seg_count
        seg_count=$($PYTHON_BIN -c "import json; d=json.load(open('$output_file')); print(len(d['segments']))" 2>/dev/null || echo "?")
        echo "  Segments: $seg_count"
    fi

    # Summarize power
    summarize_power "$TELEMETRY_DIR/${label}-powermetrics.txt"

    # Process peak memory
    if [ -f "$TELEMETRY_DIR/${label}-process.csv" ]; then
        local peak_mem
        peak_mem=$(tail -n +2 "$TELEMETRY_DIR/${label}-process.csv" | cut -d',' -f4 | sort -n | tail -1)
        local avg_cpu
        avg_cpu=$(tail -n +2 "$TELEMETRY_DIR/${label}-process.csv" | cut -d',' -f3 | awk '{s+=$1; n++} END {if(n>0) printf "%.0f", s/n; else print "0"}')
        echo "  Peak memory: ${peak_mem} MB"
        echo "  Avg CPU%: ${avg_cpu}%"
    fi

    # Write to report
    {
        echo ""
        echo "─── $name ───"
        echo "Wall clock: ${minutes}m ${seconds}s"
        echo "Segments: ${seg_count:-?}"
        echo "Exit code: $exit_code"
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
    echo "Date: $(date)"
    echo "Machine: $(sysctl -n machdep.cpu.brand_string) / $(sysctl -n hw.memsize | awk '{print $1/1073741824 "GB"}')"
    echo ""
} > "$REPORT"

# ── WhisperKit benchmarks ──
echo ""
echo "══════ WhisperKit (large-v3-turbo) ══════"
echo "WhisperKit (large-v3-turbo)" >> "$REPORT"
echo "═══════════════════════════" >> "$REPORT"

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
echo "══════ Python (mlx-whisper large-v3) ══════"
echo "" >> "$REPORT"
echo "Python (mlx-whisper large-v3)" >> "$REPORT"
echo "════════════════════════════" >> "$REPORT"

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

# ── Summary ──
echo ""
echo "══════ Complete ══════"
echo ""
echo "Report saved to: $REPORT"
echo "Telemetry saved to: $TELEMETRY_DIR/"
echo ""
echo "To view telemetry details:"
echo "  cat $TELEMETRY_DIR/*-powermetrics.txt  # GPU/ANE/CPU power"
echo "  cat $TELEMETRY_DIR/*-process.csv       # per-process CPU/memory"
echo "  cat $TELEMETRY_DIR/*-iostat.txt         # disk I/O"

# Cleanup
rm -f "$PYTHON_SCRIPT"
