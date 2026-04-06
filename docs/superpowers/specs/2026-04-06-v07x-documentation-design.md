# v0.7.x Documentation Overhaul — Design Spec

## Goal

Restructure project documentation so the full pipeline from recording to summary is clearly described, all tunable parameters are in one reference, benchmark results are preserved, and CLAUDE.md stays lean for fast context loading.

## Audience

Primary: Future sessions (Frederick + Claude) — full context without re-exploring the codebase.
Secondary: A new developer joining the project — can understand the system from scratch.

## Architecture

Six deliverables, all documentation (no code changes). Benchmark CLI tooling is out of scope — deferred to a separate spec.

## Deliverables

### 1. CLAUDE.md Slimming

**Goal:** Reduce from ~210 lines to ~80-90 lines. CLAUDE.md is loaded every Claude session — it should contain only what's needed every time.

**Keep:**
- Environment section (macOS, Apple Silicon, no Python needed)
- Project Overview (one paragraph)
- Architecture section (file listing for all targets — this is the most-used reference)
- Build & Test commands (swift build, swift test with flags)
- Branches section

**Move out:**
- Gotchas 1-48 → `docs/gotchas.md` (replace with one-line link)
- "Debugging with Unified Logging" section → `docs/pipeline.md`
- "Packaging" section → `docs/pipeline.md`

**Add:**
- Links to `docs/pipeline.md`, `docs/parameters.md`, `docs/gotchas.md`

### 2. docs/gotchas.md

**Goal:** Preserve all 48 gotchas verbatim, just in a separate file that's read on-demand rather than loaded every session.

**Content:** Move gotchas 1-48 from CLAUDE.md as-is. No rewriting. Add a header explaining these are hard-won lessons from development.

### 3. docs/pipeline.md

**Goal:** The main technical document. Describes the full end-to-end pipeline so someone can understand how a recording becomes a transcript and summary.

**Structure:**

```
# Transcription Pipeline

## Overview
One paragraph: macOS menu bar app, dual-stream recording (mic + system audio),
chunked processing, speaker diarization, echo deduplication, LLM summary.
Courtroom-grade: raw audio archive is canonical evidence, never modified.

## Pipeline Flow
ASCII diagram showing all stages in order.

## Stage Details

### 1. Audio Capture
- XPC service (AudioCaptureHelperXPC) via ScreenCaptureKit
- Two separate WAV files: system audio (48kHz mono) + microphone (native device rate)
- No pre-mixed stream available from Apple (verified through macOS 26 SDK)

### 2. Chunk Rotation
- ChunkRotator: timer-based WAV rotation (default 30min)
- Enables parallel processing of chunks while recording continues
- Crash recovery via RecordingSentinel + LaunchAgent auto-relaunch

### 3. ASR Transcription
- Model: FluidAudio Parakeet TDT 0.6B v3 (default) or Apple SpeechAnalyzer (macOS 26+)
- Input: WAV file + AudioSourceType (.system or .microphone)
- Output: [TranscriptSegment] with start, end, text, confidence, language
- FluidAudio includes ITN (Inverse Text Normalization): "three hundred" → "300"

### 4. Diarization
- Model: FluidAudio Offline Diarizer
  - Segmentation: pyannote (who speaks when)
  - Embeddings: WeSpeaker (voice fingerprint per speaker)
  - Clustering: VBx (group embeddings into speakers)
- Input: WAV file
- Output: [DiarizedSegment] with speaker IDs + speaker embedding database

### 5. VAD Speech Map
- Model: Silero VAD v6
- Runs in parallel with diarization (~100x RTF, ~1s for 4min audio)
- Output: [SpeechRegion] with per-chunk speech probability
- Used as quality signal in speaker assignment (not for audio trimming)

### 6. Speaker Assignment
- Matches ASR segments to diarization segments by temporal overlap
- VAD filters low-confidence assignments
- Tags with source prefix for dual-stream: "Local Speaker 1", "Remote Speaker 1"
- Remaps speaker database keys from raw IDs ("S2") to friendly names ("Speaker 1")

### 7. Echo Deduplication
- Purpose: Remove mic bleed (remote speaker's voice picked up by microphone)
- Algorithm: Triple-gate confirmation, all three must pass:
  1. Embedding gate: local speaker embedding cosine similarity > 0.8 with any remote speaker
  2. Temporal gate: > 50% overlap between local and remote segment
  3. Text gate: Jaccard word overlap > 0.7, OR containment > 0.7, OR windowed Jaccard > 0.7
- Windowed comparison: concatenates multiple overlapping remote segments before Jaccard
  (handles misaligned segment boundaries where local ASR merges what remote ASR splits)
- Containment fallback: checks what fraction of local words appear in remote
  (handles short local excerpts of long remote segments where Jaccard fails)
- Validation: 0 false positives across 7 recordings, see docs/benchmarks/
- Thresholds configurable via config.json (see docs/parameters.md)

### 8. Audio Archival
- Converts dual WAV → stereo AAC (L=mic, R=system) via AVAssetWriter
- Streaming encode: 65536-frame blocks, ~1MB memory (was ~1GB before v0.7.x)
- Source WAVs deleted only after archive verified
- Storage quota enforced in hours (oldest .m4a deleted first, transcripts never deleted)

### 9. Transcript Assembly
- Merges segments from all chunks, sorts by timestamp
- Cross-chunk speaker reconciliation via greedy cosine similarity on embeddings
- Outputs JSON with segments + metadata (echo_segments_removed, dual_stream, etc.)
- Also writes format file (SRT, TXT) based on config

### 10. Summary Generation
- Triggered after transcript write (fire-and-forget, never blocks pipeline)
- Provider protocol: OpenAISummaryProvider (/v1/chat/completions) or
  LMStudioSummaryProvider (/api/v1/chat with per-request context_length)
- Dual-stream awareness: transcript includes (local)/(remote) labels,
  system prompt includes text-level AEC hint telling LLM to extract genuine
  new content from local segments that overlap with concurrent remote text
- Token ratio calibration: probe → seed → first real transcript replaces seed → EMA refinement
- Self-correcting retry on context overflow (parse n_keep from error, set exact ratio, retry)

## Debugging
(Moved from CLAUDE.md: unified logging commands, dev.py usage, log stream predicates)

## Packaging
(Moved from CLAUDE.md: Package.swift targets, Info.plist, XPC bundle structure, dev.py)
```

### 4. docs/parameters.md

**Goal:** Flat reference card. Every tunable parameter, its config key, default value, and description. Organized by category.

**Categories:**
- Recording (chunk_duration_minutes, recording_directory, silence_timeout_minutes, silence_detection_enabled)
- Engine (engine, vad_speech_threshold)
- Echo Deduplication (echo_temporal_threshold, echo_text_threshold, echo_embedding_threshold)
- Audio Archive (archive_bitrate_kbps, audio_archive_limit_hours)
- Summary (summary.enabled, summary.provider, summary.endpoint, summary.api_key, summary.model, summary.context_length, summary.context_overhead_percent, summary.max_output_tokens)
- Diarization (speaker_cosine_threshold)
- System (launch_on_startup, suppress_capture_warning, chunk_processing_qos)

**Format:** One table per category with columns: Parameter | Config Key | Default | Description

**Also documents:**
- Token ratio cache file location and format (~/.audio-transcribe/token-ratios.json)
- Config file location (~/.audio-transcribe/config.json)

### 5. docs/benchmarks/2026-04-06-echo-dedup.md

**Goal:** Preserve today's benchmark data as a dated report.

**Content:**
- Setup: branch, commit, engine, hardware
- Test matrix: 7 recordings × 2 modes (legacy vs enhanced)
- Results table: recording name, legacy removed, enhanced removed, delta
- Human-verified segments: the 7 clips from multi-speaker recording with y/n verdicts
- False positive analysis: 0 across all recordings with explanation
- False negative analysis: 3 remaining, root cause (male voice embedding clustering)
- LLM summary quality: 7 summaries, per-recording verdict (PASS/PARTIAL/MINOR)
- WAV vs AAC comparison for April 5 recordings
- Methodology: CLI AAC re-processing, --legacy-dedup for A/B, afplay for human verification

### 6. scripts/test-checklist.md

**Goal:** Update from v0.6.0 to v0.7.x.

**Add sections:**
- Echo Dedup: record with YouTube on speakers, verify scores in logs, verify local speech preserved, verify bleed removed
- Summary Generation: verify LM Studio/OpenAI connectivity, check dual-stream prompt includes source labels, review summary for echo leakage
- Rename Dialog Audio: play button works, mono channel extraction, correct channel per speaker
- CLI AAC Re-processing: transcribe -i file.m4a works, --debug shows logs, echo dedup runs

**Remove:** Any v0.6.0 items that are obsolete or fully covered by automated tests.

## Out of Scope

- CLI batch benchmark tool (separate spec, deferred)
- Code changes (this is documentation only)
- README.md or ARCHITECTURE.md updates (those are less critical and can be done later)

## Success Criteria

1. CLAUDE.md is under 100 lines
2. A developer can read docs/pipeline.md and understand the full flow without reading code
3. All tunable parameters are findable in docs/parameters.md by config key name
4. Benchmark results are preserved with methodology for reproducibility
5. test-checklist.md covers all v0.7.x features
