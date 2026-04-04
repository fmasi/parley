# Audio Archive Design

**Date:** 2026-04-03
**Status:** Approved
**Version:** v0.6.0

## Problem

Each recording produces two WAV files (system audio + microphone) at ~660 MB/hour combined. Files accumulate indefinitely with no compression or cleanup. A daily user recording 1–2 hours of meetings fills ~10–20 GB/month.

## Goals

1. Compress recordings from ~660 MB/hr to ~29 MB/hr (stereo AAC at 64 kbps)
2. Preserve local/remote speaker separation for diarization re-ingestion
3. Enforce a configurable storage quota (in hours of recording) with automatic cleanup
4. Make the pipeline format-aware: accept both legacy two-WAV input and new stereo AAC input
5. Never delete transcripts — only audio is subject to the quota

## Non-Goals

- Real-time AAC encoding during recording (WAV remains the crash-safe recording format)
- Mixing/downmixing to mono at archive time (playback apps can do this)
- Auto-cleanup of transcript files (JSON/SRT/TXT are tiny, kept indefinitely)
- HE-AAC or Opus encoding (AAC-LC is sufficient and universally compatible)

## Design

### Channel Convention

Stereo AAC files use a fixed channel mapping:

- **Left channel** = local microphone (the user)
- **Right channel** = remote system audio (other meeting participants)

This convention is the contract between `AudioArchiver` (producer) and `AudioSourceResolver` (consumer). It must be documented in code and in this spec.

### System Audio Capture Rate

System audio capture is hardcoded to **48 kHz** via `SCStreamConfiguration.sampleRate`. The `sample_rate` config field is removed (deprecated — see Migration section). This eliminates the need for resampling at archive time, since microphone audio is already normalized to 48 kHz by `AudioConverter`.

### AudioSourceResolver (pipeline input layer)

New component in `TranscriberCore`. Given a recording base path, detects the input format and provides channel-separated audio streams to the pipeline.

**Input detection logic:**

1. If `{name}.wav` and `{name}_mic.wav` both exist → **legacy two-WAV format**
   - Read system WAV as remote stream
   - Read mic WAV as local stream
2. If `{name}.m4a` exists → **stereo AAC archive**
   - Decode via `AVAssetReader`
   - Split L channel → local mic stream
   - Split R channel → remote system stream
3. If none match → error

**Output:** Two PCM buffers (or temp file paths) tagged with `AudioSourceType.microphone` and `AudioSourceType.system`. Downstream code (transcription, diarization) receives the same interface regardless of source format.

**Built in v0.6.0** even though stereo AAC files won't exist until archival runs. This ensures the pipeline can re-ingest archived recordings for benchmarking and tuning from day one.

### AudioArchiver (post-processing conversion)

New component in `TranscriberCore`. Runs **after** transcription and diarization succeed.

**Steps:**

1. Open both WAV files (system + mic)
2. Read PCM data from both (already at 48 kHz, no resampling needed)
3. Interleave into stereo frames: L=mic, R=system
4. Encode to AAC-LC via `AVAssetWriter` at configured bitrate → `{name}.m4a`
5. Verify output: file exists, non-zero size, decodable (quick `AVAssetReader` open)
6. Delete both source WAV files
7. Update `metadata.audio_paths` in the transcript JSON to reference the `.m4a` file

**Error handling:** If any step fails, keep the original WAV files and log an error. Never lose audio because encoding broke.

**Bitrate:** Configurable via `archive_bitrate_kbps` (default 64). At 64 kbps stereo (32 per channel), voice is fully intelligible and spectral features are preserved for transcription/diarization re-ingestion.

### StorageManager (quota enforcement)

New component in `TranscriberCore`. Enforces the audio archive storage quota.

**Trigger:** Runs after `AudioArchiver` writes a new `.m4a` file.

**Quota logic:**

1. Scan `recordingDirectory` for `.m4a` files
2. Sum file sizes (ignore WAVs, JSON, SRT, TXT — only `.m4a` counts)
3. Convert `audio_archive_limit_hours` to bytes: `hours × archive_bitrate_kbps × 1000 / 8 × 3600`
4. If total exceeds limit, delete oldest `.m4a` files (by creation date) until under quota
5. **Never delete the recording that was just archived** — only older files

**Edge case:** If a single recording exceeds the quota (e.g., 4-hour meeting with a 2-hour limit), keep it. The quota is a target, not a hard ceiling.

### Config Changes

**New fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `archive_bitrate_kbps` | Int | 64 | AAC-LC encoding bitrate in kbps |
| `audio_archive_limit_hours` | Int | 15 | Max hours of archived audio to retain |

**Removed fields:**

| Field | Migration |
|-------|-----------|
| `sample_rate` | Log a warning on read: "sample_rate is deprecated and ignored — system audio is captured at 48 kHz". Do not write back to config. |

### Settings UI

New **"Audio Archive"** section in Settings:

- **Bitrate:** Dropdown (48 / 64 / 96 / 128 kbps), default 64
- **Archive limit:** Stepper in hours, default 15. Subtitle shows estimated disk usage: "≈ X MiB at current bitrate"
- **Current usage:** Text showing "Y MiB used (≈ Z hours)" based on actual `.m4a` files on disk

### Transcript JSON Update

After archival, `metadata.audio_paths` in the transcript JSON changes from:

```json
{
  "audio_paths": ["/path/to/recording.wav", "/path/to/recording_mic.wav"]
}
```

to:

```json
{
  "audio_paths": ["/path/to/recording.m4a"]
}
```

The `AudioSourceResolver` uses the file count and extension to determine the format.

The rename dialog must be updated: when `audio_paths` contains a single `.m4a`, it reads channel info instead of file index to determine local vs remote audio. For speaker sample playback, extract the appropriate channel (L for local speakers, R for remote speakers) before passing to `AVAudioPlayer`. Mono mixdown playback works natively — no special handling needed for casual listening.

### Processing Flow

```
Recording (live):
  ScreenCaptureKit → 2 × WAV (system@48kHz + mic@48kHz)

Processing (after recording stops):
  AudioSourceResolver detects 2 × WAV
  → TranscriptionRunner transcribes (system stream)
  → FluidAudioDiarizer diarizes (both streams, local vs remote)
  → AudioArchiver encodes stereo AAC (L=mic, R=system)
  → AudioArchiver deletes WAVs, updates JSON
  → StorageManager enforces quota

Re-ingestion (benchmarking / future re-processing):
  AudioSourceResolver detects 1 × stereo AAC
  → Splits L=mic, R=system
  → Same pipeline as above
```

## Future Considerations

### Pre-transcription conversion (revisit when trusted)

Currently, AAC conversion runs after transcription + diarization. Once the conversion code is proven reliable and latency impact is measured, move conversion to before transcription so the pipeline always operates on the archive format. This removes the dual-format window and ensures the pipeline is fully dogfooded on the archive format at all times.

**Criteria for switching:** No conversion failures in production for 4+ weeks, measured encoding latency < 5 seconds for a 1-hour recording.

### End-state vision (v0.7.0+)

The long-term goal for each meeting is three artifacts:

1. **Stereo AAC** — compressed audio archive (L=local, R=remote)
2. **Transcript JSON** — diarized transcript with timestamps and speaker labels
3. **Meeting summary** — LLM-generated minutes/summary from transcript (local or remote model, user's choice)

The user keeps perfect recall: what was said (transcript), what it sounded like (audio), and what it meant (summary).

## Release Notes

### v0.6.0 — Audio Archive

- **Breaking:** `sample_rate` config field is deprecated and ignored. System audio is now captured at 48 kHz. A warning is logged if the field is present in your config.
- **New:** Recordings are automatically compressed to stereo AAC after transcription. Left channel = your microphone, right channel = remote participants. Original WAV files are deleted after successful conversion.
- **New:** Audio Archive settings — configure encoding bitrate (default 64 kbps) and archive retention limit in hours (default 15 hours ≈ 512 MiB). Oldest recordings are automatically cleaned up when the limit is reached. Transcripts are never deleted.
- **New:** The transcription pipeline accepts both legacy WAV pairs and archived stereo AAC files as input, enabling re-processing of archived recordings for benchmarking.
