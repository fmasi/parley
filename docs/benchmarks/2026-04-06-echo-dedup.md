# Echo Dedup Benchmark — 2026-04-06

## Setup

- **Branch:** feature/v0.7.x @ commit a834593
- **Engine:** FluidAudio Parakeet TDT 0.6B v3
- **Diarization:** FluidAudio Offline (pyannote + WeSpeaker + VBx)
- **Hardware:** Apple M5 Pro, 48GB RAM, macOS 26.4

## Methodology

CLI re-processing of AAC archives via `Parley transcribe -i file.m4a`. Stereo AAC auto-split into dual mono WAVs via `AudioSourceResolver.splitChannels()`. Legacy mode (individual Jaccard only) via `--legacy-dedup` flag for A/B comparison. Human verification of ambiguous segments via `afplay` of extracted mic channel clips.

## Test Matrix

7 recordings across 2 modes (legacy vs enhanced):

| Recording | Date | Description |
|-----------|------|-------------|
| 191712-Youtube test | Apr 5 | YouTube cycling video, Frederick speaks at end |
| 205302-Only Youtube | Apr 5 | YouTube only, Frederick speaks briefly between segments |
| 210139-Youtube test 2 | Apr 5 | YouTube space video, Frederick narrates over |
| 211328-youtube at 2113 | Apr 5 | YouTube space video, short |
| 182322-Only Youtube | Apr 6 | YouTube female vocal, Frederick silent |
| 182600-Youtube + Me | Apr 6 | YouTube female vocal + Frederick talking |
| 183048-Multiple speakers + me | Apr 6 | 3-speaker male podcast + Frederick |

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

Root cause: male voice embeddings cluster closer together. The bleed speaker's embedding doesn't match any specific remote speaker above the 0.80 threshold, so the embedding gate fails to flag it.

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
| 183048-Multiple speakers + me | PARTIAL | 3 known bleed segments correctly excluded; minor bleed attribution at ~124-128s |
| 191712-Youtube test | PASS | Clean attribution |
| 205302-Only Youtube | PASS | Local speech correctly included |
| 210139-Youtube test 2 | MINOR | Bleed phrase "out of the atmosphere" leaked via a mixed ASR segment |
| 211328-youtube at 2113 | PASS | Remote-only, clean |

## WAV vs AAC Comparison

Original WAV recordings from April 5 had 0 echo removal on 3 of 4 recordings due to a speaker database key remapping bug (fixed in this branch). The difference is fixed code, not WAV vs AAC quality.

## Conclusions

1. Enhanced dedup catches 22% more bleed than legacy (windowed + containment)
2. 0 false positives — courtroom safety maintained
3. 3 false negatives in worst case (multi-male-speaker) — addressable by LLM text-level AEC
4. Current thresholds are well-calibrated — do not lower embedding threshold
