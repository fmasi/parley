# Echo Deduplication — Design Spec

**Date:** 2026-04-05
**Milestone:** v0.7.0

## Problem

When recording with system audio + microphone, the mic picks up the remote speaker's voice through physical speakers (acoustic bleed). Both channels are transcribed independently, producing near-identical duplicate segments — one from the clean system audio (R channel) and one from the mic bleed (L channel) with ~5-15ms acoustic delay.

Measured on a real recording (YouTube test, single remote speaker):
- 33/40 time buckets had overlapping segments from both sources
- 36 segment pairs were >60% text similar
- Effectively every remote speaker line appeared twice in the transcript

This degrades transcript quality and confuses the summary LLM.

## Solution

Triple-confirmed echo deduplication. A local segment is removed only when **all three signals agree**:

1. **Temporal overlap** — segments overlap by >50% of the shorter segment's duration
2. **Text similarity** — word overlap ratio >0.7
3. **Speaker embedding cosine similarity** — >0.8 between the local segment's speaker and any remote speaker

All three gates must pass for removal. This makes false positives (removing real local speech) effectively impossible.

### Text Similarity: Word Overlap Ratio

Current implementation uses simple word overlap: `|shared words| / |total unique words|`. This is sufficient because:
- Echo segments are near-identical (measured 95-100% word overlap in real data)
- Two other signals (temporal + embedding) are already confirming
- Word overlap is fast and easy to test

**If this proves insufficient later** (e.g., transcription engines produce more divergent text for the same audio, or multilingual content where word boundaries differ), upgrade to character-level Levenshtein distance normalized by max string length. The `EchoDeduplicator.textSimilarity()` method is isolated — swap the algorithm without changing the interface or thresholds. Levenshtein would catch cases like "strikes" vs "strakes" that word overlap misses, at the cost of O(n*m) computation per pair.

## Architecture

### New file: `TranscriberCore/EchoDeduplicator.swift`

```
EchoDeduplicator.deduplicate(
    segments: [LabeledSegment],
    localSpeakerDatabase: [String: [Float]],
    remoteSpeakerDatabase: [String: [Float]]
) -> [LabeledSegment]
```

Pure function. Takes merged segments (already tagged with source prefix) and both speaker databases. Returns filtered segments with echo removed.

Internal helpers (all static, testable):
- `temporalOverlap(_:_:)` — returns overlap ratio (0-1)
- `textSimilarity(_:_:)` — word overlap ratio (0-1)
- `cosineSimilarity(_:_:)` — embedding distance (0-1)
- `isEcho(local:remote:localDb:remoteDb:)` — applies all three gates

### Thresholds

| Signal | Threshold | Rationale |
|--------|-----------|-----------|
| Temporal overlap | >0.5 | Segments must overlap by more than half the shorter segment |
| Text similarity | >0.7 | Tolerates minor transcription differences between engines |
| Embedding similarity | >0.8 | Same voice, allows for mic coloring/room effects |

All three are configurable constants at the top of the file for easy tuning.

## Integration Points

### ChunkProcessor.processChunkAsync()

Between step 3 (merge + tag) and step 4 (convert to ProcessedChunk):

```
// 3b. Remove echo segments (mic bleed of remote speaker)
if hasDualStream {
    allSegments = EchoDeduplicator.deduplicate(
        segments: allSegments,
        localSpeakerDatabase: micResult.speakerDatabase,
        remoteSpeakerDatabase: systemResult.speakerDatabase
    )
}
```

### TranscriptionRunner.finalize()

Same position — after merging all chunks' segments, before assembling the transcript JSON.

## Courtroom Safety

- **Raw audio archive is untouched** — the stereo M4A with both channels is preserved as-is
- **Transcript metadata documents the dedup** — `"echo_segments_removed": N` in metadata
- **Algorithm is deterministic** — same input always produces same output
- **Triple confirmation** — no single signal can cause removal; all three must agree
- **Future AEC is additive** — acoustic noise cancellation would be a separate layer (playback-time or derivative file), not replacing this dedup

## Testing Strategy

- `EchoDeduplicatorTests`: unit tests for each helper (temporal overlap, text similarity, cosine similarity) + integration tests with realistic segment pairs
- Test with the actual YouTube recording data (known ground truth: all local segments are echo)
- Test that non-echo segments survive (local speaker saying different things than remote)
- Test edge cases: no overlap, partial overlap, similar text but different speaker

## Files

### New
- `TranscriberCore/EchoDeduplicator.swift`
- `SwiftTests/TranscriberTests/EchoDeduplicatorTests.swift`

### Modified
- `TranscriberApp/Services/ChunkProcessor.swift` — add dedup call after merge
- `TranscriberApp/Services/TranscriptionRunner.swift` — add dedup call in finalize()
- `TranscriberCore/TranscriptAssembler.swift` — add `echo_segments_removed` to metadata
