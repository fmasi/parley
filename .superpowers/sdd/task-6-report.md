# Task 6 Report — `run()` reconcile speakers across segments (H3)

## RED evidence

Added `TranscriptionRunnerReconciliationTests` (a new `@Suite` in
`SwiftTests/TranscriberTests/TranscriptionRunnerTests.swift`) with two `#expect`s driving
`TranscriptionRunner.reconcileRecoverySegments(databases:threshold:)` before the helper existed.
Filtered run failed at **compile time** (expected — a pure-function TDD unit, same pattern as
Task 5's `segmentStartOffsets`):

```
SwiftTests/TranscriberTests/TranscriptionRunnerTests.swift:48:43: error: type 'TranscriptionRunner'
has no member 'reconcileRecoverySegments'
```

## How the segment case maps onto `SpeakerReconciler`'s API

Required reading confirmed `SpeakerReconciler.reconcile(chunks: [ProcessedChunk], isDualStream:,
threshold:) -> [Int: [String: String]]` is chunk-shaped: it only reads `chunk.index`,
`chunk.speakerDatabase`, and (dual-stream) `chunk.localSpeakerDatabase`, greedily cosine-matching
each chunk's local labels against a running reference-embedding table, in `chunks` array order.
`finalize()` calls it directly on the session's real `[ProcessedChunk]` and applies the returned
`[chunkIndex: [localLabel: globalLabel]]` mapping to relabel that chunk's segments.

`run()`'s per-segment case has no `ProcessedChunk`s — each recovery/CLI segment just produces a
`speakerDatabase` (and, dual-stream, a `localSpeakerDatabase`) directly from `transcribeStream`. So
`reconcileRecoverySegments(databases: [[String: [Float]]], threshold: Double) -> [String: String]`
wraps each segment's database in a throwaway `ProcessedChunk` (`index` = segment index in the
array, `segments: []`, `startTime`/`audioPath` dummy — no other field is read by the
`isDualStream: false` single-namespace path this uses) and calls `SpeakerReconciler.reconcile`
exactly as `finalize()` does. The per-chunk-index output is then flattened into a single
`["<segmentIndex>:<localLabel>": "<globalLabel>"]` dictionary so the same raw label reused across
segments (e.g. "Speaker 1" in both segment 0 and segment 1) can never collide as a key.

This operates on **one channel at a time** — no hand-rolled cosine matcher, no dual-stream logic
duplicated. `run()` calls it twice: once for the per-segment remote (`system`) databases, once for
the per-segment local (`mic`) databases, mirroring how `finalize()` reconciles Local/Remote in
separate namespaces for dual-stream (a mic speaker never merges with a system speaker even if their
embeddings look similar).

## Implementation in `run()`

- Replaced the two naive merges (`remoteSpeakerDb.merge(...) { existing, new in existing + new }`
  and the mic equivalent) — which concatenated two different people's embedding vectors under the
  same per-segment label and never touched segment labels at all — with `perSegmentRemoteDb: [[String:
  [Float]]]` / `perSegmentLocalDb: [[String: [Float]]]`, one entry per segment (empty dict when a
  segment had no mic file), preserving per-segment structure through the loop.
- After the segment loop, before the offset-application loop: `remoteMapping` /
  `localMapping` computed via `reconcileRecoverySegments`, then the global `remoteSpeakerDb`
  / `localSpeakerDb` databases rebuilt keyed by the **reconciled** label — one representative
  embedding per global speaker (first segment it appears in), never a concatenation. These are the
  same variable names consumed downstream by `resolveUnknownsWithinSource`'s speaker-count check and
  `EchoDeduplicator.deduplicate`, so no other call site needed to change.
- In the existing offset-application loop (`for (index, offset) in segmentOffsets.enumerated()`),
  before shifting timestamps: each `systemSegs[i].speaker` / `micSegs[i].speaker` is looked up as
  `remoteMapping["\(index):\(label)"]` / `localMapping["\(index):\(label)"]` and relabeled to the
  global speaker when found. A label with no mapping entry (e.g. `"Unknown"`, which carries no
  embedding and so was never fed into the reconciler) is left as-is — never invented.
- `tagWithSourcePrefix` (unchanged, called after the merge/sort as before) then prefixes whatever
  the reconciled label is with `Local `/`Remote ` based on `source`, exactly as it already did —
  no change needed there since it operates on the final label regardless of what produced it.

## Matching-speaker test

Added both cases from the plan: `crossSegmentIdentityYieldsTwoSpeakers` (two segments, different
single speakers under `"Speaker 1"`, embeddings `[1,0,0]` vs `[0,1,0]` → `Set(mapping.values).count
== 2`) and `crossSegmentMatchingVoiceprintYieldsOneSpeaker` (same voiceprint reappearing under
`"Speaker 1"` in both segments, embeddings `[1,0,0]` vs `[0.99,0.01,0]`, well above the 0.65
threshold → `Set(mapping.values).count == 1`).

## Test results

- Filtered (`--filter TranscriptionRunnerReconciliationTests`): 2/2 pass.
- Full suite (`--filter TranscriberTests`, full flag set): **768 tests in 85 suites, all passed**
  (baseline before this task was 766 per `progress.md`; +2 = the new suite, 0 regressions).

## Concerns for final review

- `run()`'s live multi-segment relabeling path (the wiring inside `run()` itself, as opposed to
  the pure `reconcileRecoverySegments` helper) is not exercised by a dedicated unit test — `run()`
  needs real engines/diarizers and isn't unit-tested end-to-end anywhere in the suite, consistent
  with how Tasks 4 and 5 also left `run()`'s live paths to Task 7's device test.
- The representative-embedding choice for the rebuilt global `remoteSpeakerDb`/`localSpeakerDb`
  (first segment a global label appears in, not a running average) is simpler than
  `SpeakerReconciler`'s own internal exponential-moving-average reference update — that average is
  private to the reconciler and only used internally during matching, so the exposed databases here
  are best-effort representatives for `EchoDeduplicator`/`resolveUnknownsWithinSource`, not the
  reconciler's own working state. Flagged as a design choice, not a bug.
