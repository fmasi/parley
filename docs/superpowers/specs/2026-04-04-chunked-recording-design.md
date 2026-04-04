# Chunked Recording & Parallel Processing

**Date:** 2026-04-04
**Status:** Design approved
**Branch:** release/v0.6.0

## Motivation

A 4-hour meeting produces ~2.6GB of WAV files (system + mic at 48kHz). Currently, all transcription, diarization, and archiving happen after the user clicks "Stop Recording," creating a multi-minute wait. This design addresses both problems:

1. **Time-to-done** (primary): when the meeting ends, most processing is already complete. The user waits ~30s instead of 10-20 minutes.
2. **Disk footprint** (secondary): WAV files on disk never exceed one chunk's worth (~350MB for 30 minutes) because completed chunks are archived to AAC during recording.
3. **Back-to-back meetings**: decoupled processing allows starting a new recording immediately while the previous session's final chunk is still processing.

## Design Decisions

### Chunk Rotation: Zero-Gap Guarantee

WAV files are rotated on a timer (default 30 minutes). The rotation is performed as a dispatch block on the **same serial GCD queue** that receives ScreenCaptureKit audio buffer callbacks.

**Why this guarantees zero audio loss:**

ScreenCaptureKit delivers audio buffers as work items on a serial dispatch queue. "Serial" means one work item completes before the next begins. The rotation swap block (finalize current WavFileWriter, create new WavFileWriter, swap pointer in AudioOutputHandler) is dispatched on this same queue.

```
Queue: [buffer 847] [buffer 848] [SWAP BLOCK] [buffer 849] [buffer 850]
                                      |
                          finalize writer A    (~50us)
                          create writer B      (~50us)
                          swap pointer         (~ns)
```

Buffer 849 cannot arrive during the swap — it waits in the queue until the swap block completes. GCD enforces this. The swap itself takes ~100 microseconds on NVMe SSD (all Apple Silicon Macs use NVMe). The buffer delivery interval is ~21ms (1024 samples at 48kHz).

**Hardware floor:** Even on the weakest supported hardware (M1 MacBook Air, 8GB), the CPU cores are identical to other M1 variants. NVMe SSD performance is the same class. The swap is ~200x faster than the buffer delivery interval. There is no realistic scenario where the swap takes long enough to cause buffer loss.

**ScreenCaptureKit buffer queuing:** If a callback takes excessively long (many buffer intervals), SCStream may drop buffers. Our swap is ~100us against a ~21,000us budget — well within tolerance on any Apple Silicon Mac.

**Conclusion:** Zero-gap is guaranteed by architecture (GCD serial queue serialization), not by timing luck. No frames are buffered, held, or at risk during rotation.

### Chunk Naming

Chunks use 0-indexed `-N` suffix: `meeting-0.wav`, `meeting-0_mic.wav`, `meeting-1.wav`, etc.

This **unifies with crash recovery naming**. Planned rotations and crash-triggered segments use the same naming convention. The distinction between planned and unplanned segment boundaries is recorded in unified logging (`os.Logger`, category `audio`), not in filenames. Logs provide richer forensic context (timestamps, crash reasons, recovery actions) than filename conventions ever could.

### Single Code Path

All recordings — regardless of duration — go through the chunked pipeline. A 20-minute meeting with no rotation is simply a 1-chunk session. The reconciliation step is a no-op (zero pairs to compare), the merge is a passthrough (one array).

**Rationale:** Two code paths (legacy for short meetings, chunked for long) means short meetings never exercise the chunked pipeline, bugs only surface during long meetings (worst time to discover them), and quality could diverge between paths. One path means every recording tests the same code.

### Engine Parity

Diarization is architecturally decoupled from transcription. Both FluidAudio and SpeechAnalyzer produce `[TranscriptSegment]` (text + timestamps). `FluidAudioDiarizer` runs independently on raw audio — it does not depend on which engine transcribed. `SpeakerAssignment` merges both by time overlap.

The chunked pipeline is identical for both engines:
1. Transcribe chunk (engine-specific) -> `[TranscriptSegment]`
2. Diarize chunk (FluidAudioDiarizer, always) -> `[DiarizedSegment]` + embeddings
3. Assign speakers (SpeakerAssignment, shared)
4. Archive to AAC

Performance differs (FluidAudio ~100x RTF, SpeechAnalyzer ~3-98x RTF), but the flow and output format are the same.

## Architecture

### Components

#### ChunkRotator
Manages WAV file lifecycle during recording.

- Owns a repeating timer (`chunkDurationMinutes` interval)
- On fire: dispatches swap block on SCStream's serial audio queue
- Swap block: finalize current WavFileWriter pair -> create new pair -> swap reference in AudioOutputHandler
- Records wall clock time (`Date()`) at each chunk start
- Emits finalized chunk info (file paths, chunk index, start timestamp) to ChunkProcessor

#### ChunkProcessor
Background processing pipeline for completed chunks.

- Runs on a configurable QoS dispatch queue (default: `.utility`)
- Per chunk: transcribe (both streams) -> diarize -> VAD -> speaker assignment -> archive to AAC
- Persists results to `session.json` after each chunk completes (atomic write)
- Session-scoped: each recording creates its own instance. Previous session's processor continues independently, enabling back-to-back meetings.

#### SpeakerReconciler
Cross-chunk speaker label consistency.

- Consumes per-chunk `speakerDatabase: [String: [Float]]` (256D WeSpeaker embeddings)
- Uses cosine similarity with threshold 0.65 (FluidAudio's tuned threshold)
- Chunk 0's database is the reference. Subsequent chunks are matched against it.
- Unmatched embeddings (similarity < threshold) → new speaker (joined mid-meeting)
- Rolling reference update via EMA (alpha=0.9, from FluidAudio's `Speaker.updateMainEmbedding()`) to handle voice drift across many chunks

#### TranscriptMerger
Assembles final transcript from chunk results.

- Reads all processed chunks from `session.json`
- Applies speaker label remapping from SpeakerReconciler
- Converts relative timestamps to absolute (chunk wall clock start + segment offset)
- Concatenates segments chronologically
- Applies dual-stream tagging ("Remote Speaker X" / "Local Speaker Y")
- Delegates to `TranscriptAssembler.assemble()` for JSON + format file output
- Deletes `session.json` after successful assembly

### Data Flow

```
Recording:
  SCStream audio → AudioOutputHandler → WavFileWriter (current chunk)
                                              |
  Timer fires every 30min ──→ ChunkRotator ──→ swap writers on serial queue
                                              |
  Finalized chunk ──→ ChunkProcessor (background, QoS: utility)
                          ├── transcribe system audio
                          ├── transcribe mic audio
                          ├── diarize (concurrent)
                          ├── VAD analysis (concurrent)
                          ├── speaker assignment
                          ├── archive WAV → AAC
                          └── atomic write to session.json

Stop Recording:
  Finalize last chunk → process it → load session.json
      → SpeakerReconciler (cosine similarity across all chunks)
      → TranscriptMerger (remap labels, absolute timestamps, concatenate)
      → TranscriptAssembler (JSON + TXT/SRT)
      → delete session.json
```

### session.json Structure

```json
{
  "sessionId": "2026-04-04T10-00-00-standup",
  "meetingStart": "2026-04-04T10:00:00.000Z",
  "engine": "fluidAudio",
  "chunkDurationMinutes": 30,
  "chunks": [
    {
      "index": 0,
      "startTime": "2026-04-04T10:00:00.000Z",
      "audioPath": "meeting-0.m4a",
      "segments": [
        {
          "start": 0.0,
          "end": 2.5,
          "text": "Good morning everyone",
          "speaker": "spk_0",
          "source": "system",
          "qualityScore": 0.87
        }
      ],
      "speakerDatabase": {
        "spk_0": [0.12, -0.34, "...256 floats"],
        "spk_1": [0.87, 0.11, "...256 floats"]
      }
    }
  ]
}
```

Written atomically after each chunk completes. The `chunks` array grows as chunks are processed. Recovery compares `chunks.count` against audio files on disk.

### Crash Safety

**Audio integrity:** WAV files sync to disk every 0.5s (`WavFileWriter.synchronizeFile()`). Archived AAC chunks are complete files. Every second of recorded audio is recoverable after any crash.

**Processing integrity:** `session.json` is updated via atomic write (write to temp file, rename to final path) after each chunk fully completes. APFS rename is atomic — the file is either the previous valid state or the new valid state, never partial.

**Recovery logic:**
1. Count audio files on disk (WAV or AAC)
2. Count chunk entries in `session.json`
3. Difference = chunks needing reprocessing (from their audio files)
4. Worst case: one chunk in-flight during crash → ~10s reprocessing

**Guarantee:** No audio data is ever lost. Transcript state in `session.json` is never corrupted. A crash costs at most ~10 seconds of reprocessing for one chunk.

### Timestamps

Each chunk records its wall clock start time (`Date()` → ISO 8601 UTC). Segment timestamps from the engine are relative to chunk start. Absolute timestamps are computed as:

```
absolute_timestamp = chunk_start_wallclock + segment.relative_time
```

This is more accurate than `chunk_index × chunk_duration` because it captures the actual rotation timing (microsecond variance from queue scheduling).

**Final transcript contains:**
- `meeting_start`: ISO 8601, meeting start time
- `chunk_count`: number of chunks processed
- Per-segment `timestamp`: ISO 8601 absolute time (enables reverse lookup: "what was said at 10:47am?")
- Per-segment `elapsed`: seconds from meeting start (for audio playback seeking)

### Speaker Embedding Infrastructure

Currently `FluidAudioDiarizer.swift` discards speaker embeddings — only keeping timing + speaker ID + quality score. This design requires preserving:

- `TimedSpeakerSegment.embedding: [Float]` — 256D per-segment embedding
- `DiarizationResult.speakerDatabase: [String: [Float]]` — aggregated per-speaker embeddings

These are stored in `session.json` per chunk and used for cross-chunk reconciliation.

**Future foundation:** This same infrastructure enables cross-session speaker recognition (#8 priority) — recognizing "Alice" across different meetings by matching her embedding against a persistent speaker database.

### Logging

Chunk lifecycle is logged via `os.Logger` (subsystem `com.audio-transcribe.app`), invisible to the user:

```
[audio]          Chunk 0 started at 2026-04-04T10:00:00.000Z
[audio]          Chunk 0 finalized: 30m02s, 346MB (system + mic)
[transcription]  Chunk 0 processing started (qos: utility)
[transcription]  Chunk 0 transcription complete: 247 segments, 5.2s
[transcription]  Chunk 0 diarization complete: 3 speakers, 4.1s
[audio]          Chunk 0 archived: 14.2MB AAC
[transcription]  Reconciling speakers across 4 chunks (cosine threshold: 0.65)
[transcription]  Speaker remap: chunk2.spk_0 → chunk0.spk_1 (similarity: 0.94)
```

This provides a complete forensic timeline for auditing.

## Configuration

Two new JSON-only parameters in `Config.swift`:

| Parameter | Type | Default | Min | Description |
|---|---|---|---|---|
| `chunkDurationMinutes` | Int | 30 | 10 | WAV rotation interval during recording |
| `chunkProcessingQos` | String | "utility" | — | QoS for background chunk processing |

**No Settings UI.** These are power-user knobs in `~/.audio-transcribe/config.json`.

**Validation:**
- `chunkDurationMinutes` < 10 → log warning, clamp to 10
- Unknown `chunkProcessingQos` value → log warning, fall back to "utility"
- Valid QoS values: "userInteractive", "userInitiated", "utility", "background"

**Future consideration:** Auto-detect hardware capability and adjust QoS programmatically. Not in v0.6.0 scope — the JSON config covers power users in the meantime.

## Testing Strategy

### Unit Tests

- **ChunkRotator**: timer fires → swap on serial queue → correct file naming (0-indexed) → emits chunk paths → records wall clock start time
- **SpeakerReconciler**: cosine similarity matching, label remapping, threshold boundary (0.65), new speaker detection, speaker leaving, rolling EMA update
- **TranscriptMerger**: wall clock timestamp conversion, segment concatenation, speaker ID remapping, single-chunk passthrough, dual-stream tagging preserved
- **Config validation**: chunk duration clamping at min 10, QoS string parsing with fallback

### Crash Safety Tests

- `session.json` atomic write → simulate kill mid-write → previous state intact
- Recovery: N audio files on disk, M entries in session.json (M < N) → reprocess only N-M chunks
- Recovery with no session.json → reprocess all chunks from audio
- Recovery with complete session.json → no reprocessing, proceed to merge
- Chunk rotation during XPC crash → segment numbering stays consistent

### Integration Tests

- Full pipeline: multi-chunk recording → background processing → merge → final transcript matches expected output
- Single-chunk recording (short meeting) → same pipeline, same output format
- Engine parity: FluidAudio and SpeechAnalyzer produce equivalent transcript structure

### Edge Cases

- Meeting shorter than chunk duration (no rotation, 1-chunk pipeline)
- Rotation at exact chunk boundary timing
- Speaker joins in chunk 3, leaves in chunk 5
- All speakers silent for an entire chunk
- Back-to-back: start new session while previous still merging
- Two speakers with very similar voices (threshold boundary)
- Single speaker throughout entire multi-chunk meeting

## Scope

### In v0.6.0
- Chunk rotation (ChunkRotator)
- Background processing pipeline (ChunkProcessor)
- Speaker embedding extraction (stop discarding in FluidAudioDiarizer)
- Cross-chunk speaker reconciliation (SpeakerReconciler)
- Final transcript merge (TranscriptMerger)
- Absolute timestamps (ISO 8601)
- Config: `chunkDurationMinutes`, `chunkProcessingQos`
- Chunk lifecycle logging
- Crash safety (session.json atomic writes, recovery logic)
- Test coverage per testing strategy above
- Zero-gap guarantee documentation

### Out of scope (future)
- QoS auto-tuning based on hardware detection
- Persistent cross-session speaker database (#8)
- Settings UI exposure for chunk parameters
- Advanced chunk tab in Settings
