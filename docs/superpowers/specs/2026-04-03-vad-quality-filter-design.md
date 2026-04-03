# VAD Quality Filter — Design Spec

**Date:** 2026-04-03
**Branch:** `feat/vad-pre-filter`
**Status:** Approved design, pre-implementation

## Problem

The diarization pipeline assigns speaker labels to all audio, including noise segments (hold music, keyboard clicks, HVAC, silence). This produces phantom speakers in the rename dialog and pollutes transcript output. Additionally, quiet streams (e.g., mic when muted for long periods) still go through full diarization compute even when most of the audio is non-speech.

## Design Decision: VAD as Parallel Signal, Not Pre-Processor

We considered three approaches:

1. **Pre-processing (mask/trim audio before diarizer)** — Rejected. Modifying the diarizer's input couples Silero VAD's speech detection with pyannote's internal segmentation, making it impossible to isolate accuracy drift. Every future tuning run for Fa/Fb/excludeOverlap would be confounded by the VAD mask. Timestamp remapping adds fragile complexity.

2. **Post-processing only (filter diarizer output)** — Partial. Catches noise in output but doesn't leverage existing signals like `qualityScore`.

3. **Parallel signal in SpeakerAssignment** — Chosen. VAD runs independently, produces a speech probability map, and SpeakerAssignment fuses it with diarization output and `qualityScore`. Each signal is independently tunable, observable, and testable.

### Key Principle: Isolate Accuracy Drift

Each pipeline stage must be independently measurable so parameter changes can be attributed to the right component:

```
Audio → ASR          → TranscriptSegments        (text + timestamps)
Audio → Diarizer     → DiarizedSegments           (speaker + timestamps + qualityScore)
Audio → VAD          → SpeechMap                   (speech probability per time region)

(TranscriptSegments, DiarizedSegments, SpeechMap) → SpeakerAssignment → LabeledSegments
```

Diarizer always sees the original unmodified audio. VAD is a parallel input to SpeakerAssignment, not a transform on the diarizer's input.

## Architecture

### New Component: `VadSpeechMap`

A lightweight wrapper that runs `VadManager` on an audio file and produces time-indexed speech probabilities.

**File:** `TranscriberCore/VadSpeechMap.swift`

```swift
/// Time-indexed speech probability from Silero VAD.
/// Used as a parallel quality signal in SpeakerAssignment.
public struct SpeechRegion: Sendable {
    public let start: Double      // seconds, wall-clock time
    public let end: Double        // seconds, wall-clock time
    public let probability: Float // 0.0 (silence/noise) to 1.0 (confident speech)
}

public actor VadSpeechMap {
    /// Analyze audio and return speech regions with probabilities.
    /// Returns nil if VAD model is not cached (graceful degradation).
    func analyze(audioPath: URL) async throws -> [SpeechRegion]?

    /// Check speech overlap ratio for a time range.
    /// Returns 0.0–1.0 indicating what fraction of [start, end] contains speech.
    static func speechOverlap(
        regions: [SpeechRegion],
        start: Double,
        end: Double,
        threshold: Float
    ) -> Double

    /// Model cache management (integrates with existing download flow).
    static func isModelCached() -> Bool
    static func preDownloadModel() async throws
}
```

### Changed Component: `SpeakerAssignment`

**File:** `TranscriberCore/SpeakerAssignment.swift`

Add a new `assign` overload that accepts the speech map:

```swift
public static func assign(
    transcriptSegments: [TranscriptSegment],
    diarizationSegments: [DiarizedSegment],
    speechMap: [SpeechRegion]?           // nil = VAD unavailable, skip filtering
) -> [LabeledSegment]
```

#### Combined Filtering Logic

Each transcript segment is evaluated with two signals:

| VAD Speech Overlap | Diarizer qualityScore | Decision |
|----|----|----|
| High (≥ threshold) | High (≥ threshold) | Confident — assign speaker |
| High (≥ threshold) | Low (< threshold) | Real speech, uncertain speaker — assign "Unknown" |
| Low (< threshold) | High (≥ threshold) | Trust diarizer (rare) — assign speaker |
| Low (< threshold) | Low (< threshold) | Noise — filter from output |

Default thresholds (tunable):
- `vadSpeechThreshold`: 0.5 (fraction of segment that must overlap with speech)
- `qualityScoreThreshold`: configurable, needs benchmarking to determine initial value

When `speechMap` is nil (model not cached), the function falls back to current behavior (no VAD filtering, qualityScore still applied).

### Changed Component: `FluidAudioDiarizer`

**File:** `TranscriberCore/FluidAudioDiarizer.swift`

Model download integration:
- `preDownloadModels()` also downloads the Silero VAD model
- `isDiarizationCached()` also checks for VAD model presence

The diarizer itself is unchanged — it still processes the original audio. VAD runs as a separate step.

### Changed Component: `TranscriptionRunner`

**File:** `TranscriberApp/Services/TranscriptionRunner.swift`

In `transcribeStream()`, after ASR and before/alongside diarization:

```swift
// Run VAD in parallel with diarization (both read the same audio file)
async let diarizedSegments = diarizer.diarize(audioPath: audioPath, numSpeakers: nil)
async let speechMap = vadSpeechMap.analyze(audioPath: audioPath)

// Fuse all three signals
labeled = SpeakerAssignment.assign(
    transcriptSegments: segments,
    diarizationSegments: try await diarizedSegments,
    speechMap: try? await speechMap   // nil on failure = graceful degradation
)
```

VAD runs concurrently with diarization — near-zero added latency since VAD completes in ~1–2s while diarization takes 30+s.

## What Does NOT Change

- ASR pipeline (FluidAudioEngine, SpeechAnalyzerEngine)
- Diarizer input (always original unmodified audio)
- XPC audio capture service
- UI (MenuView, SettingsView, SetupView)
- Timestamp format (all wall-clock, no remapping)
- Existing `--diarize-sweep` and `--diarize-params` benchmark tools (they continue to measure raw diarizer output)

## Testing & Benchmarking Strategy

### Unit Tests

New test suite: `SwiftTests/TranscriberTests/VadSpeechMapTests.swift`

1. **SpeechOverlap calculation** — pure logic, no model needed:
   - Full overlap: segment entirely within speech region → 1.0
   - No overlap: segment entirely in silence → 0.0
   - Partial overlap: segment spans speech boundary → proportional value
   - Multiple speech regions spanning one segment
   - Empty speech map → 0.0

2. **Combined filtering logic** — test the decision matrix:
   - High speech + high quality → speaker assigned
   - High speech + low quality → "Unknown"
   - Low speech + low quality → filtered out
   - Nil speech map → fallback to current behavior
   - qualityScore nil (engine doesn't provide it) → treat as high quality

### Benchmark Tool Extensions

**File:** `tools/engine-benchmark/` additions

#### `--vad-analysis` flag
Run VAD on audio files and report speech statistics without running diarization. Useful for understanding the input signal before tuning.

Output:
```
Speech ratio: 72.3% (43.4 min / 60.0 min)
Speech segments: 847
Mean segment duration: 3.1s
Silence gaps > 5s: 12
Noise regions (speech < 0.3): 4 (total 2.1 min)
```

#### `--vad-filter` flag on existing `--diarize-sweep`
Run diarization sweep with VAD filtering enabled/disabled side-by-side:

```
Parameters: Fa=0.03, Fb=0.5, excludeOverlap=false

Without VAD filter:
  Speakers: 3 (106/73/14 segments)
  Noise segments assigned to speakers: 8

With VAD filter (threshold=0.5):
  Speakers: 3 (104/72/14 segments)
  Filtered as noise: 5 segments (total 1.2s)
  qualityScore filtered: 3 segments
```

This lets you see exactly what VAD filtering adds/removes compared to raw diarization.

#### `--quality-score-histogram` flag
Report distribution of qualityScore values across all diarized segments:

```
qualityScore distribution:
  0.0–0.2: ████ 12 segments
  0.2–0.4: ██ 6 segments
  0.4–0.6: ███ 8 segments
  0.6–0.8: █████████████ 45 segments
  0.8–1.0: ████████████████████ 120 segments
```

This establishes baselines for choosing `qualityScoreThreshold`.

### Debugging Workflow

#### Isolating accuracy changes

When diarization quality changes unexpectedly:

1. **Reproduce without VAD** — set `speechMap: nil` in SpeakerAssignment (or toggle a config flag). If quality returns to previous level → VAD threshold needs tuning. If not → diarizer parameter issue.

2. **Compare VAD vs diarizer on same audio:**
   ```bash
   # What VAD thinks is speech
   swift run engine-benchmark --vad-analysis recording.wav

   # What diarizer produces (raw, no VAD filter)
   swift run engine-benchmark --diarize-params recording.wav

   # Combined (with VAD filter)
   swift run engine-benchmark --diarize-params --vad-filter recording.wav
   ```

3. **Check what was filtered** — unified logging at `category: "transcription"`:
   ```
   VAD filtered segment [12.3s–14.1s] Speaker 2: speechOverlap=0.12, qualityScore=0.15
   VAD kept segment [14.5s–18.2s] Speaker 1: speechOverlap=0.94, qualityScore=0.87
   ```

4. **Tune independently:**
   - `vadSpeechThreshold` — controls how much speech must overlap a segment to keep it
   - `qualityScoreThreshold` — controls minimum embedding quality
   - Diarizer params (Fa/Fb/excludeOverlap) — unchanged, tuned separately

### Integration Test Checklist

Update `scripts/test-checklist.md` with VAD-specific items:

- [ ] Record with background music → verify music segments filtered, not labeled as speaker
- [ ] Record meeting with long muted period → verify silence doesn't create phantom speaker
- [ ] Record with keyboard noise → verify clicks filtered from transcript
- [ ] Record normal meeting → verify no real speech segments lost (false negative check)
- [ ] Toggle VAD on/off in config → verify fallback behavior (nil speechMap)
- [ ] Fresh install without VAD model cached → verify graceful degradation
- [ ] Check rename dialog → verify filtered segments don't appear as speaker samples

## Model Download Integration

The Silero VAD model (~2MB) is small compared to ASR (~500MB) and diarization (~10MB) models.

- **Setup flow:** Download alongside diarization models when FluidAudio engine is selected
- **Settings Save:** Re-download if missing
- **Graceful degradation:** If VAD model not cached, `VadSpeechMap.analyze()` returns nil, SpeakerAssignment falls back to current behavior (no filtering)
- **Cache check:** `VadSpeechMap.isModelCached()` added to existing `FluidAudioDiarizer.isDiarizationCached()`

## Configuration

Add to `Config`:

```swift
/// VAD quality filter threshold. Fraction of a transcript segment that must
/// overlap with VAD-detected speech to be kept. Set to 0.0 to disable VAD filtering.
/// Default: 0.5
var vadSpeechThreshold: Double?
```

When nil or 0.0, VAD filtering is disabled (useful for benchmarking raw diarizer output).

## Open Questions for Benchmarking

These will be resolved during implementation through actual recordings:

1. **What's the right `vadSpeechThreshold`?** — Need histogram data from real meetings to pick a value that filters noise without clipping real speech. Start at 0.5, tune with `--vad-filter`.

2. **What's the right `qualityScoreThreshold`?** — Need `--quality-score-histogram` data first. The diarizer may produce very different score distributions for system audio (mixed mono) vs mic audio (clean single speaker).

3. **Does VAD add value beyond qualityScore alone?** — Run A/B: qualityScore-only filtering vs VAD+qualityScore. If qualityScore alone is sufficient, VAD may not be needed.

## Scope

**In scope:**
- VadSpeechMap actor
- SpeakerAssignment changes (VAD + qualityScore filtering)
- Model download integration
- Unit tests for overlap calculation and filtering logic
- Benchmark tool flags (--vad-analysis, --vad-filter, --quality-score-histogram)
- Logging for filtered segments
- Config field for vadSpeechThreshold

**Out of scope (separate features):**
- Audio masking/trimming (rejected for testability reasons)
- WAV stream merging for playback
- Streaming VAD during recording
- Cross-session speaker recognition (embeddings database)

## Research Findings & Rejected Approaches

This section documents what we learned during design so future sessions have full context if the landscape changes.

### FluidAudio API Constraints (v0.13.4, checked 2026-04-03)

1. **`OfflineDiarizerManager` has no speech mask API.** The `process()` method accepts either a file URL or `[Float]` samples — there is no way to pass pre-computed speech regions, VAD segments, or a time mask to the diarizer. It runs its own internal pyannote segmentation unconditionally.

2. **`OfflineDiarizerConfig` controls internal segmentation thresholds** (`speechOnsetThreshold`, `speechOffsetThreshold`, `minDurationOn`, `minDurationOff`) but these tune pyannote's powerset model, not an external VAD signal. They cannot substitute for Silero VAD's speech detection.

3. **`VadManager` is a standalone component** — completely separate from the diarization pipeline. It uses Silero VAD v6 (CoreML). It has `process()` for per-chunk probabilities and `segmentSpeech()` for extracting speech time ranges with hysteresis. RTFx ~100x (extremely fast).

4. **`DiarizedSegment.qualityScore`** is available in the diarizer output but currently ignored in our `SpeakerAssignment.assign()`. This is a free signal that indicates embedding confidence per segment.

### Approach: Pre-processing (audio masking) — Rejected

**What:** Load audio into `[Float]`, run VAD, zero out non-speech samples, pass masked audio to `OfflineDiarizerManager.process(audio:)`.

**Why it was attractive:** Prevents noise embeddings from entering VBx clustering. Diarizer processes same-length audio (no timestamp remapping). Potentially speeds up embedding extraction (pyannote would see silence, produce fewer speaker segments).

**Why we rejected it:**
- Couples Silero VAD's and pyannote's definitions of "speech" — when accuracy changes, you can't isolate whether it was VAD masking or diarizer params (Fa/Fb/excludeOverlap)
- We've already invested in tuning Fa/Fb/excludeOverlap independently. Adding masking underneath makes every future tuning run harder to interpret.
- VAD false negatives silently drop real speech from diarization with no recovery

**What would change this decision:** If `OfflineDiarizerManager` adds a `speechRegions: [VadSegment]` parameter that it uses internally during embedding extraction (preserving its own segmentation but filtering embeddings), that would be the ideal API. Worth checking on FluidAudio updates.

### Approach: Pre-processing (trimmed WAV) — Rejected

**What:** Run VAD, write a new WAV containing only speech segments (gaps removed), pass to diarizer + ASR.

**Why we rejected it:**
- Requires timestamp remapping for all diarizer output (trimmed-time → wall-clock time). Remapper is ~20 lines but the failure mode is invisible: off-by-one errors silently shift speaker labels in time.
- Creates temp files that need cleanup (crash risk for leaks)
- Same accuracy isolation problem as masking
- If applied to ASR too, ASR timestamps also need remapping before SpeakerAssignment can match them with diarizer output

**What would change this decision:** If the diarizer's processing time becomes a measurable bottleneck on long recordings AND the parallel-signal approach proves insufficient for quality, the speed/quality trade-off might justify the complexity. Would need profiling data first.

### Approach: In-memory masking without file — Considered but deprioritized

**What:** Same as masking but using `process(audio: [Float])` instead of writing a file.

**Advantage over trimming:** No temp files, no timestamp remapping (same-length array, wall-clock timestamps preserved).

**Why deprioritized:** Still has the accuracy isolation problem (modifies diarizer input, confounds tuning). The parallel-signal approach achieves the output quality goal without this trade-off. If benchmarking shows that noise embeddings are actually contaminating VBx clustering beyond what post-filtering can fix, this approach could be reconsidered as an additive optimization.

### Approach: Skip diarization on quiet streams — Rejected

**What:** If VAD says < 10% speech on a stream, skip diarization entirely and label all segments as "Speaker 1".

**Why rejected:** The mic stream can have multiple local speakers (confirmed by user). Skipping diarization would lose speaker attribution for anyone else in the room. The optimization only saves time on the mic stream, not the system stream where diarization matters most.

### FluidAudio Features to Watch

These could change the design landscape in future versions:

| Feature | Impact on this design | Where to check |
|---|---|---|
| `OfflineDiarizerManager` speech mask API | Would enable clean pre-filtering without accuracy isolation loss | FluidAudio releases, `OfflineDiarizerConfig` |
| Cross-session speaker embeddings (#8) | `TimedSpeakerSegment.embedding` could provide per-segment confidence that's better than `qualityScore` for filtering | FluidAudio #355, `OfflineDiarizerManager` result type |
| Sortformer diarizer improvements | End-to-end model may handle noise better internally, reducing need for VAD filtering | `SortformerDiarizer` (currently max 4 speakers) |
| Silero VAD v7+ model updates | May improve speech/noise discrimination, affecting threshold tuning | FluidAudio VAD model registry |

### DeepWiki Reference

Full FluidAudio documentation indexed at: https://deepwiki.com/FluidInference/FluidAudio
- VAD overview: `/3.3-voice-activity-detection-(vad)`
- VadManager API: `/3.3.1-vadmanager-and-processing-modes`
- Offline diarizer pipeline: `/3.2.2-offlinediarizermanager-(batch-pipeline)`
- Speaker management: `/3.2.3-speaker-management-and-clustering`
