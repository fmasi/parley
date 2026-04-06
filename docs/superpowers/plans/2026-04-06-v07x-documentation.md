# v0.7.x Documentation Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure project documentation so the full pipeline is clearly described, parameters are in one reference, benchmark results are preserved, and CLAUDE.md stays lean.

**Architecture:** Six documentation deliverables. No code changes. CLAUDE.md is slimmed by extracting gotchas, debugging, and packaging sections into dedicated docs. New pipeline.md describes the end-to-end flow. New parameters.md is the tunable parameters reference. Benchmark report preserves today's test results. Test checklist updated for v0.7.x.

**Tech Stack:** Markdown documentation only.

---

### Task 1: Extract gotchas from CLAUDE.md to docs/gotchas.md

**Files:**
- Create: `docs/gotchas.md`
- Modify: `CLAUDE.md` (lines 119-167, the "Key Gotchas" section)

- [ ] **Step 1: Create docs/gotchas.md**

Create `docs/gotchas.md` with the following content. Copy the 48 gotchas verbatim from `CLAUDE.md` lines 119-167 (the entire "## Key Gotchas" section), prefixed with this header:

```markdown
# Platform & Implementation Gotchas

Hard-won lessons from development. Referenced from [CLAUDE.md](../CLAUDE.md).

These are numbered for stable cross-referencing — new items are appended, never re-numbered.
```

Then paste all 48 gotchas exactly as they appear in CLAUDE.md (lines 120-167), preserving numbering and formatting.

- [ ] **Step 2: Replace gotchas section in CLAUDE.md**

In `CLAUDE.md`, replace the entire `## Key Gotchas` section (lines 119-167) with:

```markdown
## Key Gotchas
See [docs/gotchas.md](docs/gotchas.md) — 48 platform-specific gotchas (macOS APIs, ScreenCaptureKit, XPC, audio formats, TCC, Liquid Glass, engine quirks). New items are appended there.
```

- [ ] **Step 3: Verify CLAUDE.md line count dropped**

Run: `wc -l CLAUDE.md`
Expected: ~160 lines (down from ~208). The gotchas section was ~49 lines.

- [ ] **Step 4: Commit**

```bash
git add docs/gotchas.md CLAUDE.md
git commit -m "docs: extract 48 gotchas from CLAUDE.md to docs/gotchas.md"
```

---

### Task 2: Extract debugging and packaging from CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (lines 169-204, "Debugging with Unified Logging" and "Packaging" sections)

These sections will be moved to `docs/pipeline.md` in Task 3. For now, remove them from CLAUDE.md and add forward links.

- [ ] **Step 1: Save the debugging section content**

Read `CLAUDE.md` lines 169-196 (the "## Debugging with Unified Logging" section). Save this content — it will be placed in `docs/pipeline.md` in Task 3.

- [ ] **Step 2: Save the packaging section content**

Read `CLAUDE.md` lines 198-204 (the "## Packaging" section). Save this content — it will be placed in `docs/pipeline.md` in Task 3.

- [ ] **Step 3: Replace both sections in CLAUDE.md with links**

Replace the "Debugging with Unified Logging" section (lines 169-196) with:

```markdown
## Debugging
See [docs/pipeline.md](docs/pipeline.md#debugging) for unified logging commands and dev.py usage.

Quick reference:
\```bash
# All logs (debug + info + error)
log stream --predicate 'subsystem == "com.audio-transcribe.app"' --level debug

# Via dev.py (launches app + tails log)
python3 scripts/dev.py --debug
\```
```

Replace the "Packaging" section (lines 198-204) with:

```markdown
## Packaging
See [docs/pipeline.md](docs/pipeline.md#packaging) for bundle structure, Info.plist, and XPC service details.
```

- [ ] **Step 4: Add documentation links after Build & Test section**

After the "## Build & Test" section (around line 118, before the gotchas link), add:

```markdown
## Documentation
- [docs/pipeline.md](docs/pipeline.md) — End-to-end pipeline: recording → transcription → summary
- [docs/parameters.md](docs/parameters.md) — All tunable parameters with config keys and defaults
- [docs/gotchas.md](docs/gotchas.md) — 48 platform-specific gotchas
- [docs/benchmarks/](docs/benchmarks/) — Dated benchmark reports
```

- [ ] **Step 5: Verify CLAUDE.md line count**

Run: `wc -l CLAUDE.md`
Expected: ~100 lines (down from ~160 after Task 1).

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: slim CLAUDE.md — move debugging and packaging to pipeline.md"
```

---

### Task 3: Create docs/pipeline.md

**Files:**
- Create: `docs/pipeline.md`

This is the main deliverable. It describes the full pipeline from recording to summary.

- [ ] **Step 1: Create docs/pipeline.md**

Create `docs/pipeline.md` with the full content. The document must include these sections in order:

1. **Overview** — One paragraph: macOS menu bar app, dual-stream recording (mic + system audio via ScreenCaptureKit XPC service), chunked processing, speaker diarization, echo deduplication, LLM summary generation. Courtroom-grade: raw audio archive is canonical evidence, never modified. All derivative artifacts (transcripts, summaries) are clearly marked as processed output.

2. **Pipeline Flow** — ASCII diagram:
```
Recording (XPC)
  ├── System audio WAV (48kHz mono)
  └── Microphone WAV (native device rate)
       │
  ChunkRotator (30min WAV rotation)
       │
  ┌────┴────┐
  │ Per Chunk │
  ├──────────┤
  │ ASR Transcription (FluidAudio Parakeet / SpeechAnalyzer)
  │    ↓
  │ Diarization (pyannote + WeSpeaker + VBx) ←→ VAD (Silero, parallel)
  │    ↓
  │ Speaker Assignment (overlap + VAD quality filter)
  │    ↓
  │ Source Tagging ("Local Speaker 1", "Remote Speaker 1")
  │    ↓
  │ Echo Deduplication (embedding → temporal → text)
  │    ↓
  │ Audio Archival (dual WAV → stereo AAC, L=mic R=system)
  └──────────┘
       │
  Speaker Reconciliation (cross-chunk cosine matching)
       │
  Transcript Assembly (JSON + SRT/TXT)
       │
  Summary Generation (LLM, fire-and-forget)
```

3. **Stage Details** — For each of the 10 stages, write a subsection with:
   - What it does (1-2 sentences)
   - Model or engine used (with version/name)
   - Input → Output (data types)
   - Key code path (file.swift:functionName)
   - Any critical gotchas (link to docs/gotchas.md#N where relevant)

   The 10 stages are:
   - Audio Capture — XPC service, ScreenCaptureKit, dual WAV. Code: `AudioCaptureService.swift`, `AudioOutputHandler.swift`
   - Chunk Rotation — Timer-based 30min WAV rotation. Code: `ChunkRotator.swift`
   - ASR Transcription — FluidAudio Parakeet TDT 0.6B v3 (default) or SpeechAnalyzer (macOS 26+). Code: `FluidAudioEngine.swift`, `SpeechAnalyzerEngine.swift`
   - Diarization — FluidAudio offline: pyannote segmentation + WeSpeaker embeddings + VBx clustering. Code: `FluidAudioDiarizer.swift`
   - VAD Speech Map — Silero VAD v6, ~100x RTF, parallel with diarization. Code: `VadSpeechMap.swift`
   - Speaker Assignment — Overlap-based matching, VAD quality filtering, source prefix tagging, DB key remapping. Code: `SpeakerAssignment.swift`
   - Echo Deduplication — Triple-gate: embedding cosine >0.8, temporal overlap >0.5, text Jaccard/containment/windowed >0.7. Code: `EchoDeduplicator.swift`. Include brief explanation of windowed comparison and containment fallback. Reference benchmark: "0 false positives across 7 recordings (see [benchmarks](benchmarks/2026-04-06-echo-dedup.md))."
   - Audio Archival — Streaming dual WAV → stereo AAC via AVAssetWriter, 65536-frame blocks. Code: `AudioArchiver.swift`. L=mic, R=system convention.
   - Transcript Assembly — Merge chunks, reconcile speakers via cosine on embeddings, write JSON+format files. Code: `TranscriptAssembler.swift`, `TranscriptMerger.swift`, `SpeakerReconciler.swift`
   - Summary Generation — Provider protocol, OpenAI-compatible or LM Studio native API. Dual-stream prompt with text-level AEC hint. Token ratio calibration. Code: `MeetingSummarizer.swift`, `OpenAISummaryProvider.swift`, `LMStudioSummaryProvider.swift`, `TokenRatioCache.swift`

4. **Echo Deduplication Deep Dive** — A dedicated subsection explaining:
   - The problem (mic bleed from speakers)
   - Triple-gate algorithm with the three thresholds
   - Why all three gates required (embedding alone insufficient for multi-speaker, text alone fails on segment boundary mismatch)
   - Windowed comparison: when local ASR merges what remote ASR splits
   - Containment fallback: when local is a short excerpt of a long remote
   - LLM text-level AEC: the summary prompt that instructs the LLM to extract genuinely new content from mixed local segments
   - Courtroom safety: raw audio never modified, removals tracked in metadata (`echo_segments_removed`), thresholds configurable

5. **Summary Generation** — Dedicated subsection:
   - Provider protocol design (OpenAI now, Apple Intelligence later)
   - Dual-stream prompt with source labels and text-level AEC hint
   - Token ratio calibration lifecycle (probe → seed → real measurement → EMA → self-correction)
   - Fire-and-forget: summary never blocks pipeline

6. **Debugging** — Move content from CLAUDE.md's "Debugging with Unified Logging" section here. All `log stream` commands, `dev.py --debug`, log categories, historical log dumps.

7. **Packaging** — Move content from CLAUDE.md's "Packaging" section here. Package.swift targets, Info.plist files, dev.py, test-checklist.

8. **CLI Reference** — Document all CLI subcommands:
   - `transcribe -i <file> [--output-dir] [-f format] [--engine] [--no-diarize] [--debug] [--legacy-dedup]` — supports both WAV pairs and single stereo AAC
   - `rename -i <file>` — interactive CLI speaker rename
   - `rename-gui -i <file>` — GUI speaker rename dialog
   - `benchmark [--transcription-only] [--diarization-only]` — engine performance benchmark
   - `summarize -i <file> [--provider] [--endpoint] [--api-key] [--model] [--context-length]` — generate summary from transcript JSON

- [ ] **Step 2: Verify the document reads coherently**

Read the document from top to bottom. Check:
- All 10 stages are covered
- Code paths reference files that actually exist
- No placeholder text ("TBD", "TODO")
- ASCII diagram is legible

- [ ] **Step 3: Commit**

```bash
git add docs/pipeline.md
git commit -m "docs: add end-to-end pipeline documentation"
```

---

### Task 4: Create docs/parameters.md

**Files:**
- Create: `docs/parameters.md`

- [ ] **Step 1: Create docs/parameters.md**

Create `docs/parameters.md` with the following structure. All parameter names, config keys, and defaults must match the actual code in `TranscriberCore/Config.swift`.

```markdown
# Tunable Parameters

All parameters are set in `~/.audio-transcribe/config.json`. Parameters not present in the file use their default values. The config file uses `snake_case` keys.

## Recording

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Recording directory | `recording_directory` | `~/Documents/Recordings` | Output directory for recordings and transcripts |
| Chunk duration | `chunk_duration_minutes` | 30 | WAV file rotation interval in minutes |
| Silence detection | `silence_detection_enabled` | true | Auto-stop recording after silence timeout |
| Silence timeout | `silence_timeout_minutes` | 5 | Minutes of silence before auto-stop |
| Last microphone | `last_microphone_device_id` | — | Persisted mic device selection (set by UI) |

## Engine

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Transcription engine | `engine` | `resolved_default` | `fluid_audio` or `speech_analyzer`. Default resolves to FluidAudio on macOS 15, SpeechAnalyzer on macOS 26+ |
| Output format | `output_format` | `json` | `json`, `srt`, or `txt` |
| VAD speech threshold | `vad_speech_threshold` | 0.5 | Minimum speech probability for VAD quality filtering (0.0-1.0) |

## Echo Deduplication

These are config-file-only parameters (not exposed in the UI). Omit to use defaults.

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Temporal threshold | `echo_temporal_threshold` | 0.5 | Minimum temporal overlap ratio to consider a pair (0.0-1.0) |
| Text threshold | `echo_text_threshold` | 0.7 | Minimum Jaccard / containment score to confirm echo (0.0-1.0) |
| Embedding threshold | `echo_embedding_threshold` | 0.8 | Minimum cosine similarity between speaker embeddings (0.0-1.0) |

## Audio Archive

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| AAC bitrate | `archive_bitrate_kbps` | 64 | Encoding bitrate for stereo AAC archives (kbps) |
| Storage quota | `audio_archive_limit_hours` | 15 | Maximum hours of audio archives to keep. Oldest .m4a files deleted first. Transcripts never deleted. |

## Summary

Nested under the `summary` key in config.json (e.g., `"summary": {"enabled": true, ...}`).

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Enabled | `summary.enabled` | false | Auto-generate summary after transcription |
| Provider | `summary.provider` | `openai` | `openai` (OpenAI-compatible API) or `lmstudio` (LM Studio native REST API v1) |
| Endpoint | `summary.endpoint` | — | LLM API base URL (e.g., `http://127.0.0.1:1234`) |
| API key | `summary.api_key` | — | Bearer token for authentication (optional for local models) |
| Model | `summary.model` | — | Model identifier (e.g., `unsloth/gemma-4-e4b-it`) |
| Context length | `summary.context_length` | — | Max context window (LM Studio only, auto-sized if omitted) |
| Context overhead | `summary.context_overhead_percent` | 10 | Extra context percentage for safety margin |
| Max output tokens | `summary.max_output_tokens` | 2048 | Token budget reserved for LLM response |

## System

| Parameter | Config Key | Default | Description |
|-----------|-----------|---------|-------------|
| Launch on startup | `launch_on_startup` | true | Install LaunchAgent for auto-relaunch |
| Suppress capture warning | `suppress_capture_warning` | false | Hide the "recording in progress" warning |
| Chunk processing QoS | `chunk_processing_qos` | `utility` | GCD QoS for background chunk processing (`userInteractive`, `userInitiated`, `utility`, `background`) |

## Speaker Reconciliation

Not currently exposed in config.json — hardcoded defaults in code.

| Parameter | Code Location | Default | Description |
|-----------|--------------|---------|-------------|
| Cosine threshold | `SpeakerReconciler.reconcile()` | 0.65 | Minimum cosine similarity for cross-chunk speaker matching |

## Token Ratio Cache

Stored at `~/.audio-transcribe/token-ratios.json`. Managed automatically — no manual editing needed.

| Field | Description |
|-------|-------------|
| `ratio` | Characters per token for this model (e.g., 3.06) |
| `isSeed` | `true` if from calibration probe, `false` if from real transcript measurement |

Lifecycle: probe calibration → seed stored → first real transcript (>2000 chars) replaces seed → subsequent transcripts refine via EMA (0.3 new + 0.7 cached) → context overflow self-corrects with exact ratio from error.
```

- [ ] **Step 2: Verify all config keys match Config.swift**

Read `TranscriberCore/Config.swift` and cross-reference every `CodingKeys` entry against the parameters.md table. No key should be missing from the doc, no doc entry should reference a nonexistent key.

- [ ] **Step 3: Commit**

```bash
git add docs/parameters.md
git commit -m "docs: add tunable parameters reference"
```

---

### Task 5: Create docs/benchmarks/2026-04-06-echo-dedup.md

**Files:**
- Create: `docs/benchmarks/2026-04-06-echo-dedup.md`

- [ ] **Step 1: Create the benchmark report**

Create `docs/benchmarks/2026-04-06-echo-dedup.md` with the following content. All data comes from the benchmark run performed in this session.

```markdown
# Echo Dedup Benchmark — 2026-04-06

## Setup

- **Branch:** feature/v0.7.x @ commit a834593
- **Engine:** FluidAudio Parakeet TDT 0.6B v3
- **Diarization:** FluidAudio Offline (pyannote + WeSpeaker + VBx)
- **Hardware:** Apple M5 Pro, 48GB RAM, macOS 26.4

## Methodology

CLI re-processing of AAC archives via `AudioTranscribe transcribe -i file.m4a`.
Stereo AAC auto-split into dual mono WAVs via `AudioSourceResolver.splitChannels()`.
Legacy mode (individual Jaccard only) via `--legacy-dedup` flag for A/B comparison.
Human verification of ambiguous segments via `afplay` of extracted mic channel clips.

## Test Matrix

7 recordings across 2 modes (legacy vs enhanced):

| Recording | Date | Description | Duration |
|-----------|------|-------------|----------|
| 191712-Youtube test | Apr 5 | YouTube cycling video, Frederick speaks at end | ~4 min |
| 205302-Only Youtube | Apr 5 | YouTube only, Frederick speaks briefly between segments | ~2 min |
| 210139-Youtube test 2 | Apr 5 | YouTube space video, Frederick narrates over | ~2 min |
| 211328-youtube at 2113 | Apr 5 | YouTube space video, short | ~1.5 min |
| 182322-Only Youtube | Apr 6 | YouTube female vocal, Frederick silent | ~2 min |
| 182600-Youtube + Me | Apr 6 | YouTube female vocal + Frederick talking | ~3.5 min |
| 183048-Youtube multiple speakers + me | Apr 6 | 3-speaker male podcast + Frederick | ~5 min |

## Results

| Recording | Legacy Removed | Enhanced Removed | Delta | Surviving Local |
|-----------|---------------|-----------------|-------|----------------|
| 191712-Youtube test | 32 | 38 | +6 | 1 |
| 205302-Only Youtube | 15 | 18 | +3 | 5 |
| 210139-Youtube test 2 | 6 | 7 | +1 | 7 |
| 211328-youtube at 2113 | 9 | 10 | +1 | 0 |
| 182322-Only Youtube (female) | 16 | 21 | +5 | 0 |
| 182600-Youtube + Me | 20 | 25 | +5 | 10 |
| 183048-Multiple speakers + me | 31 | 39 | +8 | 13 |
| **Total** | **129** | **158** | **+29 (22%)** | |

## False Positive Analysis

**Result: 0 false positives across all 7 recordings.**

No genuine speech was incorrectly removed. The embedding gate reliably separates Frederick's voice (cosine 0.185-0.506 against remote speakers) from bleed (cosine 0.965-0.967). The 0.80 threshold sits comfortably in the gap.

## False Negative Analysis

**3 false negatives, all in the multi-speaker male podcast (183048):**

| Time | Text | Source | Root Cause |
|------|------|--------|-----------|
| 221.1-222.1s | "Is there an opportunity?" | YouTube bleed | Embedding gate passed — male voice too close to remote |
| 241.2-242.7s | "It's cheaper than we get it for." | YouTube bleed | Same — male clustering |
| 275.7-279.0s | "Instead of being a giant store with loads of product." | YouTube bleed | Same |

Root cause: male voice embeddings cluster closer together. The bleed speaker's embedding doesn't match any specific remote speaker above the 0.80 threshold, so the embedding gate fails to flag it. Jaccard/containment gates never get a chance.

## Human-Verified Segments (183048)

Frederick confirmed via `afplay` of extracted mic channel clips:

| Time | Text | Frederick? | Verdict |
|------|------|-----------|---------|
| 124.2-126.0s | "I do think we'll play the devil's advocate." | Y | Correct keep |
| 126.0-127.8s | "There is um how much they're gonna sell." | Y | Correct keep |
| 168.2-170.0s | "Well, because they're more profit margins." | Y | Correct keep |
| 221.1-222.1s | "Is there an opportunity?" | N | False negative |
| 241.2-242.7s | "It's cheaper than we get it for." | N | False negative |
| 273.9-275.7s | "So he doesn't charges for that." | Y | Correct keep |
| 275.7-279.0s | "Instead of being a giant store with loads of product." | N | False negative |

## LLM Summary Quality

Summaries generated via Gemma 4 E4B Instruct (unsloth/gemma-4-e4b-it, Q6_K_XL) with dual-stream text-level AEC prompt.

| Recording | Verdict | Notes |
|-----------|---------|-------|
| 182322-Only Youtube | PASS | Remote-only, clean attribution |
| 182600-Youtube + Me | PASS | Frederick's test narration correctly treated as non-meeting content |
| 183048-Multiple speakers + me | PARTIAL | 3 known bleed segments correctly excluded. "Local Speaker 4" gets minor attribution from other bleed at ~124-128s |
| 191712-Youtube test | PASS | Clean attribution |
| 205302-Only Youtube | PASS | Local speech correctly included |
| 210139-Youtube test 2 | MINOR | Bleed phrase "out of the atmosphere" leaked via a mixed ASR segment |
| 211328-youtube at 2113 | PASS | Remote-only, clean |

## WAV vs AAC Comparison (April 5 recordings)

Original WAV recordings from April 5 had 0 echo removal on 3 of 4 recordings due to a speaker database key remapping bug (fixed in this branch). The AAC re-process with the same legacy algorithm gets 32, 15, 6, 9 removals. The difference is fixed code, not WAV vs AAC quality.

## Conclusions

1. **Enhanced dedup catches 22% more bleed** than legacy (windowed + containment)
2. **0 false positives** — courtroom safety maintained
3. **3 false negatives** in worst case (multi-male-speaker) — addressable by LLM text-level AEC in summary
4. **Current thresholds are well-calibrated** — do not lower embedding threshold (would risk FP on Frederick's voice in mixed scenarios)
```

- [ ] **Step 2: Commit**

```bash
git add docs/benchmarks/2026-04-06-echo-dedup.md
git commit -m "docs: add echo dedup benchmark report (2026-04-06)"
```

---

### Task 6: Update scripts/test-checklist.md

**Files:**
- Modify: `scripts/test-checklist.md`

- [ ] **Step 1: Update test-checklist.md to v0.7.x**

Replace the entire content of `scripts/test-checklist.md` with:

```markdown
# Test Checklist — v0.7.x

## Echo Deduplication
- [ ] Record with YouTube on speakers (no headphones), speak a few sentences
- [ ] After transcription, check logs: `log stream --predicate 'subsystem == "com.audio-transcribe.app"' --level debug | grep "Echo dedup"`
- [ ] Verify embedding scores visible (not `<private>`) — should show cosine values
- [ ] Verify your speech is preserved (Local Speaker segments with your words)
- [ ] Verify YouTube bleed is removed (echo_segments_removed > 0 in JSON metadata)
- [ ] Open transcript JSON — confirm no local segments contain text identical to remote segments

## Summary Generation
- [ ] Verify LM Studio running with model loaded
- [ ] After transcription + rename dialog, verify summary auto-generates
- [ ] Check -summary.md file created alongside transcript
- [ ] For dual-stream: verify transcript in summary prompt includes (local)/(remote) labels
- [ ] Review summary — no echo content attributed to local speakers

## Rename Dialog
- [ ] After transcription, rename dialog appears
- [ ] Play button works — audio plays through both speakers (mono extraction)
- [ ] Correct channel: local speaker plays mic audio, remote speaker plays system audio
- [ ] Multiple samples: forward button cycles through samples
- [ ] Rename and save — verify names updated in JSON and SRT/TXT

## CLI AAC Re-processing
- [ ] `AudioTranscribe transcribe -i file.m4a` — splits and processes stereo AAC
- [ ] `--debug` flag streams logs to stderr
- [ ] Echo dedup runs (check echo_segments_removed in output JSON)
- [ ] Output JSON written to same directory as input (or --output-dir)

## Audio Archive
- [ ] Record a meeting (system + mic), verify .m4a created after transcription
- [ ] Verify .m4a is stereo (L=mic, R=system)
- [ ] Verify source WAV files deleted after successful archival
- [ ] Verify transcript JSON audio_paths points to .m4a

## Chunked Recording
- [ ] Start recording — verify chunk-0 files created with `-0` suffix
- [ ] Wait past chunk duration (set to 1min for testing) — verify rotation in logs
- [ ] Stop after rotation — verify final transcript has speech from both chunks
- [ ] Speaker labels consistent across chunks in final transcript

## Regression
- [ ] Start recording, stop, verify transcription completes
- [ ] Rename dialog works after transcription
- [ ] Settings save and reload correctly
- [ ] XPC crash during recording — verify recovery
```

- [ ] **Step 2: Commit**

```bash
git add scripts/test-checklist.md
git commit -m "docs: update test-checklist.md for v0.7.x"
```

---

## Self-Review

**1. Spec coverage:**
- CLAUDE.md slimming → Task 1 (gotchas) + Task 2 (debugging/packaging)
- docs/gotchas.md → Task 1
- docs/pipeline.md → Task 3
- docs/parameters.md → Task 4
- docs/benchmarks/2026-04-06-echo-dedup.md → Task 5
- scripts/test-checklist.md → Task 6
All spec requirements covered.

**2. Placeholder scan:** No TBD/TODO. All tasks have exact content. Task 3 is the most content-heavy — the step instructs the implementer to write all 10 stages with specific details per stage.

**3. Type consistency:** No code types involved — all markdown. File paths are consistent across tasks (docs/gotchas.md, docs/pipeline.md, docs/parameters.md referenced the same way in CLAUDE.md links and task descriptions).
