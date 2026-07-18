# Task 5 Report — `run()` cumulative per-segment time offsets (H2)

## RED evidence

Added `SwiftTests/TranscriberTests/TranscriptionRunnerTests.swift` with three `#expect`s driving
`TranscriptionRunner.segmentStartOffsets(durations:)` before the helper existed. Filtered run
failed at **compile time** (expected — a pure-function TDD unit, not a runtime assertion):

```
error: type 'TranscriptionRunner' has no member 'segmentStartOffsets'
```
(three occurrences, one per test, at `TranscriptionRunnerTests.swift:12/16/20`)

## Implementation

- `TranscriptionRunner.segmentStartOffsets(durations: [Double]) -> [Double]` — `nonisolated`
  (needed so the Swift Testing suite, which is not `@MainActor`, can call it synchronously without
  hopping actors; `TranscriptionRunner` itself is `@MainActor`). Pure running-sum: `offsets[0] ==
  0`, `offsets[k] == sum(durations[0..<k])`.
- After GREEN on the 3 helper tests (`cumulativeOffsets`, `singleSegmentHasNoOffset`, and one extra
  edge case `noSegmentsYieldsNoOffsets` for the empty-array case), applied it inside `run()`:
  the segment loop now transcribes each segment's system/mic streams into **per-segment** arrays
  (`perSegmentSystem`/`perSegmentMic`) instead of appending straight into `allSegments`. After the
  loop, a `segmentDurations` array is built — one entry per segment — and fed to
  `segmentStartOffsets` to get `segmentOffsets`; each segment's own segments then get `start`/`end`
  shifted by its offset before the final merge into `allSegments`. Segment 0's offset is always 0,
  so single-file behaviour is byte-for-byte unchanged (verified: full suite green, no existing
  test's expectations moved).

## Duration source chosen

**Primary: physical WAV length**, via the existing `SpeakerSampleLocator.durations(of:)` helper
(`TranscriberCore/SpeakerSampleLocator.swift:89`, already used in production for the rename-dialog
sample-locator path) — `AVAudioFile(forReading:).length / sampleRate` on each segment's **system**
WAV (`segmentPair.system`), read after `repairSegmentHeaders` has already run, so a header
truncated by a mid-recording kill is fixed before this read. This is accurate even when ASR/VAD
trims leading/trailing silence from the transcript, and it was already proven reliable elsewhere
in the codebase, so I did not need the transcript-based fallback as the primary source.

**Fallback: that segment's own transcript max `end`** — used only if `SpeakerSampleLocator.durations`
returns `nil` for a segment (WAV genuinely unreadable even after repair — corrupt/zero-length). A
warning is logged (`Logger.transcription.warning`) noting the degraded case. Tradeoff: in that rare
path, a transcript that trimmed trailing silence understates the segment's real duration, so every
later segment's offset would be slightly short (shifted earlier than the true wall-clock time) —
strictly better than the pre-fix behavior of *no* offset at all, and it only engages when the
physical read has already failed.

## Doc fix (`SegmentDiscovery.swift`)

Removed the two false "timestamps are absolute" claims (top-of-file doc comment and the gap
comment further down). Replaced with: per-segment WAVs are file-relative; `run()` applies
cumulative offsets from physical segment durations; a gap in the index sequence still gets
stitched in (discovery itself never drops it) but that missing segment's unknown duration means
every later segment's offset is short by exactly that amount — stated as a limitation, not silently
assumed away.

## Test results

- Filtered (`--filter TranscriptionRunnerTests`): 3/3 pass.
- Full suite (`--filter TranscriberTests`, full flag set): **766 tests in 84 suites, all passed**
  (baseline before this task was 763 per `progress.md`; +3 = the new suite, 0 regressions).

## Concerns for final review

- The fallback path (transcript-max-end when the physical WAV is unreadable) is not itself
  unit-tested — it would require constructing a segment whose WAV read fails after repair, which
  isn't easily reachable from a pure/fake-free test. Flagged, not blocking: the primary path (which
  every real crash-recovery scenario hits) is exercised by the 3 helper tests plus the full-suite
  regression run.
- Single-file / CLI behaviour is unchanged by construction (offset 0 for the only segment), not by
  a new regression test targeting `run()` directly — `run()` isn't unit-tested end-to-end anywhere
  in the suite (it needs real engines), consistent with how Task 4 also left `run()`'s live paths to
  device testing (Task 7).
