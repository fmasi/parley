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

## Why v1.4-AEC

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
  adaptive-filter front end). A feature request for it is drafted.
- On weak echo it removes less than the joint models (call B: 15 echo-like lines left, against 3–4).
  `EchoDeduplicator` stays and still flags what's left.

## Engine: LocalVQE's filter in C++, the residual mask on Core ML (decided 2026-10-30)

- **Filter**: upstream `daf_frontend.{h,cpp}` (localai-org/LocalVQE @ `7f61cd0`, Apache-2.0), about 450
  lines of plain C++, vendored by `scripts/vendor-localvqe.sh` into `ThirdParty/CLocalVQE/upstream` with
  its two ggml-typed loaders removed. No ggml.
- **Mask**: soniqo's Core ML export of the same model (HF `aufklarer/LocalVQE-v1.4-AEC-200K-CoreML` @
  `10e904d`, built from our exact GGUF). It does not load on macOS 27.0.1: Core ML refuses any stateful
  model with more than one state, or one state and more than one output (reproduced with a 4-element
  toy model). `scripts/build-localvqe-coreml.py` rebuilds the same program, op for op with the same
  fp16 weights, with its seven states packed into one, into `ThirdParty/LocalVQE-CoreML` (0.7 MB).
  `model.mil` and the weights rebuild byte for byte; Core ML's `coremldata.bin` differs per compile.
- **Speed** (25-min call, M5 Pro): 34 s (44× real time), against 98 s for the ggml engine on 4 threads
  and 40 s for FluidAudio's v1.3. CPU, GPU and ANE take the same time; we run CPU-only, the same answer on
  every Mac. Measure on the M1 Air.
- **Against the ggml engine**: 21 dB SNR, not bit-identical. Ruled out: the filter (soniqo's port and
  upstream's are bit-identical), the delay estimate, fp32 arithmetic, fp32 weights, the STFT (the
  model's learned transform is the windowed DFT to 1e-4). Left: the export of the mask itself. Scored on
  the three calls it removes the same echo (visible echo lines 0 / 15 / 15, ggml 0 / 15 / 12) and cuts
  slightly more near-end speech where the far end is silent (0.4 / 0.2 / 0.8 %, ggml 0.0 / 0.1 / 0.3 %):
  the frames the near-end guard reverts.
- ggml timings, for the record (idle M5 Pro, 25 min): 1 / 2 / 4 / 6 / 8 threads = 171 / 126 / 98 / 102 /
  121 s. Splitting a chunk into parallel pieces left echo behind; the Core ML path makes it moot.

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
8. **Model**: bundled in the app (`Contents/Resources/LocalVQE-CoreML`, 0.7 MB, Apache-2.0); every file
   is checked against `MANIFEST.json` (SHA-256) at load. No download, so the airgap rule holds.

## Tasks

| # | Task | Model, effort | Why |
|---|---|---|---|
| 1 | Vendor the filter (`scripts/vendor-localvqe.sh`), build the Core ML mask (`scripts/build-localvqe-coreml.py`), `CLocalVQE` target | done (Opus) | |
| 2 | ~~Patch out ggml's dynamic backend loading~~ | dropped: no ggml left | |
| 3 | `LocalVQEEchoCanceller` (filter + STFT + Core ML mask, manifest check), the pure `NearEndGuard`, the file-level `LocalVQEMicEchoCanceller` seam, with tests | done (Opus) | |
| 4 | Wire into `ChunkProcessor` + config key + failure path + metadata + issue codes | Opus, high | Pipeline; touches the record |
| 5 | `TranscriptRediarizer` + CLI flag | Sonnet, high | Follows 3–4's API |
| 6 | Settings toggle + docs (CLAUDE.md map, parameters, pipeline, gotchas: macOS 27 multi-state Core ML models, coremldata.bin not reproducible; README models + licences) | Sonnet, medium | Copy and docs |
| 7 | Review: code council over the diff, then `/ci-review` in rounds | Fable, high (reviewer ≠ builder) | Final review |
| 8 | Device test on real speakerphone calls + a known-text test (one person reading a page, a video playing through the speakers, a second person across the room) | Owner + Haiku, low for scoring | Measurement in the PR |

## Owner decisions (2026-10-30)

1. Vendor in this repo: yes. 2. Bundle the model in the app, no download and no opt-out yet: yes.
3. Off for the first release; `auto` (speaker route only) after the device test: yes.
4. The Core ML path rather than the ggml engine: yes.

## Not in scope

- Live (during-capture) cancellation. Everything stays chunked and offline.
- Parley's text dedup changes. `EchoDeduplicator` is untouched.
