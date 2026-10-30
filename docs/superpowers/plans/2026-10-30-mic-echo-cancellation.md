# Mic echo cancellation (LocalVQE v1.4-AEC), plan

Issue: #342 (with #39, #183, #252). Status: **draft for the owner's review**. Nothing here is merged
or enabled.

## Goal

On a speakerphone call the mic records the far end coming back out of the speakers. Today
`EchoDeduplicator` flags that echo after ASR, from text. It can't separate echo from the user's
own words once ASR has fused them into one line (gotcha 48), and it misses echo that ASR transcribes
differently (2026-10-29 call: 50 echo lines flagged, 52 still visible). The fix is to cancel the echo
in the audio, using the system track as the far-end reference, on a **derived copy** of the mic that
only ASR and diarization read. The raw mic, the archive and the speaker samples stay untouched.

## Why v1.4-AEC, and why the upstream engine

Measured 2026-10-29/30 on three real calls (French, desktop speakers, a webcam and a Bluetooth mic)
and on FluidAudio's 200-clip English set. "Near-end cut" is the share of 100 ms frames inside
near-end speech, with the far end silent, that the model cut by 20 dB or more. Those frames hold no
echo, so anything cut there is the user's words.

| | v1.3 joint (FluidAudio) | v1.2 joint (FluidAudio) | **v1.4-AEC echo only (upstream)** |
|---|---|---|---|
| Near-end cut, call A / B / C | 31 % / 18 % / 12 % | 7 % / 11 % / 12 % | **0 % / 0.1 % / 0.3 %** |
| Echo lines left visible, call A (raw: 16 visible + 50 flagged) | 3 | 2 | **0** |
| English synthetic set: near-end word recall | 77 % | 73 % | not run (no harness) |

- The joint models' **noise suppression** is what removes quiet near-end speech (a second person in
  the room, soft speech). v1.4-AEC removes only the echo and keeps voice, noise and room. That is the
  courtroom rule: echo left in can be seen and flagged; a word removed is silent loss.
- FluidAudio ships v1.2 and v1.3 only. Its docs list v1.4-AEC as "not included" (GGUF-only, a C++
  adaptive-filter front end). A feature request for it is drafted. Until it lands we use the
  upstream engine (route 2); if FluidAudio adds it, we switch and delete the vendored code.
- On weak echo it removes less than the joint models (call B: 15 echo-like lines left, against 3–4).
  `EchoDeduplicator` stays and still flags what's left.

## Engine facts (measured)

- Upstream `localai-org/LocalVQE` at `7f61cd0`, ggml vendored at `c044a8e` with LocalVQE's
  `ggml-gru.patch`. Apache-2.0 (LocalVQE) and MIT (ggml). Model
  `localvqe-v1.4-aec-200K-f32.gguf`, 2.9 MB.
- **It builds from source with SwiftPM**: 75 files (2.8 MB), CPU backend + Accelerate, no Metal and
  no BLAS. A clean release build takes 10 s. Its output matches the upstream CLI to 61.7 dB SNR (the CLI
  writes 16-bit). Prototype in the session scratchpad (`pkg/LocalVQEKit`).
- **Threads**: auto is min(4, cores). On an idle M5 Pro, 25 min of audio takes 171 / 126 / 98 / 102 /
  121 s on 1 / 2 / 4 / 6 / 8 threads, with identical output. 4 is the knee; more is slower. Measure on
  the M1 Air; it may need min(4, performance cores).
- **Speed against FluidAudio's Core ML models**, same call: v1.2 24 s (64× real time), v1.3 40 s (37×),
  v1.4-AEC 98 s (15×). v1.4 runs on the CPU in 16 ms hops; about 2 extra minutes per 30-minute chunk.
- **No splitting a chunk into parallel pieces.** The model gets better over a long continuous run.
  Eight parallel pieces took 46 s instead of 100 s but left 4–6 echo lines instead of 0, even with a 30 s
  overlap. One context per chunk, run in order.
- Delay mic vs reference on call A: ~63 ms drifting to ~57 ms over 25 min. Alignment is inside the
  model.

## Design

1. **Setting** `mic_echo_cancel` (`off` by default; a later `auto` would turn it on only when the
   output route is a speaker). Settings → Transcription: "Remove speaker echo from my mic (on-device)".
2. **Where**: `ChunkProcessor.processChunkAsync`, between the system and mic passes. When it's on and the
   chunk is dual-stream, `MicEchoCanceller` (TranscriberCore, behind a protocol seam) reads the
   chunk's mic and system WAVs at 16 kHz mono, runs one LocalVQE context over the whole chunk at
   `chunkProcessingQos`, and writes `chunk-N-mic-aec.wav` in the chunk's scratch directory. ASR and
   diarization of the local stream read that file. The raw mic WAV is still what gets archived.
3. **Near-end guard** (pure, tested): in 100 ms frames, where the far end has been silent for 500 ms
   and the raw mic is above −45 dBFS, the cleaned mic must not drop by more than 20 dB. Each such
   frame is replaced with the raw mic (50 ms crossfades) and counted. This is the erase metric above
   turned into a safety net: v1.4-AEC should almost never trip it, and a model change that does
   gets caught and reported.
4. **Failure**: any error (model missing, engine returns non-zero, length mismatch) means the raw mic
   is used, plus a `ChunkIssue` `.echoCancelFailed`. Never a missing local transcript.
5. **Record**: `metadata.mic_echo_cancel = {engine, model_sha256, chunks, frames_reverted}`, and a
   per-chunk issue code when frames were reverted. `CaptureQualityNotice` doesn't announce it; it's
   provenance.
6. **Re-detect** (`TranscriptRediarizer`) on the mic channel reruns diarization from audio. It must
   apply the same cancellation (same model, same guard) when the transcript says it was used, or
   speakers drift between the first pass and a re-detect.
7. **CLI** `transcribe --split` gets `--echo-cancel` so the benchmark path matches the app.
8. **Model**: bundled in the app (2.9 MB, Apache-2.0) and verified by SHA-256 at load. No download,
   so the airgap rule holds trivially. `ModelManifest` records it.
9. **Dynamic loading**: ggml's `ggml_backend_load_all*` scans directories for backend dylibs. Patch it
   out (CPU backend registered statically) so the engine never `dlopen`s anything.

## Tasks

| # | Task | Model, effort | Why |
|---|---|---|---|
| 1 | `scripts/vendor-localvqe.sh`: fetch the pinned commits, apply the patch, copy the 75 files to `ThirdParty/LocalVQE`, write `VERSION` + licences; `CLocalVQE` target in `Package.swift` | Sonnet, medium | Mechanical; the file list and defines are known from the prototype |
| 2 | Patch out dynamic backend loading; check no `dlopen` is left | Opus, medium | Small, but it's a security property |
| 3 | `MicEchoCanceller` (Swift wrapper over the C API: whole-chunk, thread cap, SHA check) + the pure `NearEndGuard` with tests (synthetic tone echo, near-end tone kept, guard reverts injected cuts) | Opus, high | New seam, numerics, tests must be red-first |
| 4 | Wire into `ChunkProcessor` + config key + failure path + metadata + issue codes | Opus, high | Pipeline; touches the record |
| 5 | `TranscriptRediarizer` + CLI flag | Sonnet, high | Follows 3–4's API |
| 6 | Settings toggle + docs (CLAUDE.md map, parameters, pipeline, gotchas: 8-thread slowdown, no chunk splitting; README models + licences) | Sonnet, medium | Copy and docs |
| 7 | Review: code council over the diff, then `/ci-review` in rounds | Fable, high (reviewer ≠ builder) | Final review |
| 8 | Device test on real speakerphone calls + a known-text test (one person reading a page, a video playing through the speakers, a second person across the room) | Owner + Haiku, low for scoring | Measurement in the PR |

## Owner decisions before task 1

1. Vendor the sources into this repo (auditable, no binary; +2.8 MB of C/C++), or a separate package
   repo? **Recommended: vendor, with the script.**
2. Bundle the model in the app (recommended) or download it at Setup?
3. Default `off` for the first release, with `auto` (speaker route only) after the device test?

## Not in scope

- Live (during-capture) cancellation. Everything stays chunked and offline.
- Parley's text dedup changes. `EchoDeduplicator` is untouched.
