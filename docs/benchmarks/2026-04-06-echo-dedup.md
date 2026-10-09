# Echo Dedup Benchmark — 2026-04-06

## Setup

- **Branch:** feature/v0.7.x @ commit a834593
- **Engine:** FluidAudio Parakeet TDT 0.6B v3
- **Diarization:** FluidAudio Offline (pyannote + WeSpeaker + VBx)
- **Hardware:** Apple M5 Pro, 48GB RAM, macOS 26.4

## Methodology

CLI re-processing of AAC archives via `Parley transcribe -i file.m4a`. Stereo AAC auto-split into dual mono WAVs via `AudioSourceResolver.splitChannels()`. Legacy mode (individual Jaccard only) via a `--legacy-dedup` flag that existed at the commit above for this A/B comparison; it was removed afterwards (8621203), so this run cannot be repeated as written, and the enhanced algorithm measured here was itself replaced by cluster-level detection in #256. Human verification of ambiguous segments via `afplay` of extracted mic channel clips.

## Test Matrix

7 recordings across 2 modes (legacy vs enhanced):

| Recording | Date | Description |
|-----------|------|-------------|
| R1 | Apr 5 | YouTube cycling video, Frederick speaks at end |
| R2 | Apr 5 | YouTube only, Frederick speaks briefly between segments |
| R3 | Apr 5 | YouTube space video, Frederick narrates over |
| R4 | Apr 5 | YouTube space video, short |
| R5 | Apr 6 | YouTube female vocal, Frederick silent |
| R6 | Apr 6 | YouTube female vocal + Frederick talking |
| R7 | Apr 6 | 3-speaker male podcast + Frederick |

## Results

| Recording | Legacy Removed | Enhanced Removed | Delta | Surviving Local |
|-----------|---------------|-----------------|-------|----------------|
| R1 | 32 | 38 | +6 | 1 |
| R2 | 15 | 18 | +3 | 5 |
| R3 | 6 | 7 | +1 | 7 |
| R4 | 9 | 10 | +1 | 0 |
| R5 | 16 | 21 | +5 | 0 |
| R6 | 20 | 25 | +5 | 10 |
| R7 | 31 | 39 | +8 | 13 |
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
| R5 | PASS | Remote-only, clean attribution |
| R6 | PASS | Frederick's test narration correctly treated as non-meeting content |
| R7 | PARTIAL | 3 known bleed segments correctly excluded; minor bleed attribution at ~124-128s |
| R1 | PASS | Clean attribution |
| R2 | PASS | Local speech correctly included |
| R3 | MINOR | Bleed phrase "out of the atmosphere" leaked via a mixed ASR segment |
| R4 | PASS | Remote-only, clean |

## WAV vs AAC Comparison

Original WAV recordings from April 5 had 0 echo removal on 3 of 4 recordings due to a speaker database key remapping bug (fixed in this branch). The difference is fixed code, not WAV vs AAC quality.

## Conclusions

1. Enhanced dedup catches 22% more bleed than legacy (windowed + containment)
2. 0 false positives — courtroom safety maintained
3. 3 false negatives in worst case (multi-male-speaker) — addressable by LLM text-level AEC
4. Current thresholds are well-calibrated — do not lower embedding threshold
