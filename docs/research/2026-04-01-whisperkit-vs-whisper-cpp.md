# WhisperKit vs whisper.cpp Research (April 2026)

## WhisperKit (by Argmax)

**What it is:** A native Swift package for on-device speech-to-text using **Core ML** (not MLX). Runs Whisper models converted to Core ML format on Apple Neural Engine + GPU. Includes CLI tool (`whisperkit-cli`).

**GitHub:** argmaxinc/WhisperKit — 5,892 stars, MIT license, latest v0.18.0 (April 1, 2026), very actively maintained.

**Installation:** Pure SPM. Add `https://github.com/argmaxinc/WhisperKit` to Package.swift dependencies. Also available via Homebrew (`brew install whisperkit-cli`).

**Platforms:** macOS 13+, iOS 16+, watchOS 10+, visionOS 1+. swift-tools-version: 5.9.

**Model support:** All Whisper variants — tiny, base, small, medium, large-v2, large-v3, large-v3-turbo. Models are Core ML format, hosted at `argmaxinc/whisperkit-coreml` on HuggingFace. **Downloaded on demand** via HuggingFace Hub (not bundled). Can also use local model folder.

**Key API:**
```swift
// Initialize (downloads model if needed)
let whisperKit = try await WhisperKit(WhisperKitConfig(model: "large-v3-turbo"))

// Transcribe from file
let results = try await whisperKit.transcribe(audioPath: "path/to/audio.wav")

// Transcribe from float array (16kHz mono PCM)
let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: "audio.wav")
let results = try await whisperKit.transcribe(audioArray: audioArray)
```

**Streaming:** WhisperKit has a `segmentDiscoveryCallback` for getting segments as they're produced during file transcription. For true real-time streaming (live mic), they push toward **Argmax Pro SDK** (commercial, 14-day trial). The open-source version can do chunked processing but doesn't have a turnkey live-streaming API.

**Language detection:** Supported for multilingual models. Can auto-detect language from audio. Per-segment language detection is possible via `DecodingOptions`.

**Core ML vs MLX:** WhisperKit uses **Core ML exclusively** (ANE + GPU). This is fundamentally different from mlx-whisper which uses MLX (GPU-only compute). Core ML can leverage the Neural Engine which is extremely power-efficient.

**Dependencies:** `swift-transformers` (HuggingFace Hub + Tokenizers).

---

## SpeakerKit (Part of WhisperKit repo)

**What it is:** On-device speaker diarization framework, open-sourced in v0.17.0 (March 2026). Lives in the same WhisperKit repo as a separate target/library.

**Diarization model:** Uses **Pyannote v4 (community-1)** segmentation and embedding models, converted to Core ML format. Models hosted at `argmaxinc/speakerkit-coreml` on HuggingFace. ~10 MB total.

**Quality vs pyannote.audio:** Blog claims it "matches the error rate of state-of-the-art systems such as Pyannote across 13 datasets" — meaning DER parity with server-side pyannote. They published an Interspeech 2025 paper and open-sourced SDBench for reproducible benchmarks.

**Speed:** ~1 second for 4 minutes of audio on iPhone. Order of magnitude faster than pyannote.audio on CPU.

**Maturity:** Just open-sourced (March 2026). The commercial Argmax Pro SDK now uses NVIDIA Sortformer instead, so they open-sourced the Pyannote implementation. API is clean but young.

**Can process files:** Yes. Takes `[Float]` audio array (16kHz mono PCM):
```swift
let speakerKit = try await SpeakerKit()  // downloads pyannote Core ML models
let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: "meeting.wav")
let diarization = try await speakerKit.diarize(audioArray: audioArray)

// Combine with transcription
let segments = diarization.addSpeakerInfo(to: transcription, strategy: .subsegment)

// Export RTTM
let rttm = SpeakerKit.generateRTTM(from: diarization, transcription: transcription)
```

**Key features:**
- Auto-estimates number of speakers or accepts manual count
- Produces speaker segments with start/end times
- Can merge with WhisperKit transcription results (word-level speaker assignment)
- Standard RTTM export
- Conforms to `Diarizer` protocol — pluggable backends

---

## whisper.cpp (by ggml-org)

**What it is:** Plain C/C++ implementation of Whisper inference. No dependencies. **Not a Swift package** — it's a C library with a C-style API (`whisper.h`).

**GitHub:** ggml-org/whisper.cpp — 48,181 stars, MIT license, stable v1.8.1, very actively maintained.

**Swift bindings:** No official Swift bindings in the repo. Bindings exist for Go, Java, JavaScript, Ruby. Third-party Swift wrapper **SwiftWhisper** (exPHAT/SwiftWhisper, 774 stars) wraps whisper.cpp as a git submodule in an SPM package, but it's a community project with 63 commits total — not heavily maintained.

**Model support:** All Whisper variants (tiny through large-v3-turbo). Uses custom **GGML binary format** (`.bin` files). Supports integer quantization (Q4, Q5, Q8) for smaller/faster models. Models downloadable from `huggingface.co/ggerganov/whisper.cpp`.

**Apple Silicon optimization:** ARM NEON, Accelerate framework, **Metal** GPU acceleration, and optional **Core ML** support (encoder only — must generate `.mlmodelc` separately via Python script). Metal is the primary GPU path.

**Streaming:** Has a `whisper-stream` example that samples audio every 0.5s from microphone via SDL2. This is a C program, not a library API — you'd need to build equivalent logic yourself.

**Can process files:** Yes, the core use case. `whisper-cli` processes WAV/audio files.

**No diarization:** whisper.cpp has no speaker diarization capability at all.

**VAD:** Recently added Voice Activity Detection support.

---

## Comparison Matrix

| Feature | WhisperKit | whisper.cpp |
|---|---|---|
| **Language** | Swift (SPM) | C/C++ (CMake) |
| **Swift integration** | Native, first-class | Via C interop or SwiftWhisper wrapper |
| **Inference backend** | Core ML (ANE + GPU) | Metal + Accelerate (optional Core ML encoder) |
| **Model format** | Core ML (.mlmodelc) | GGML (.bin), supports quantization |
| **Model variants** | All Whisper variants | All Whisper variants + quantized |
| **Model delivery** | HuggingFace download on demand | Manual download or script |
| **File transcription** | Yes | Yes |
| **Streaming** | Partial (callbacks); full via Pro SDK | Example code, not library API |
| **Speaker diarization** | Yes (SpeakerKit, Pyannote Core ML) | No |
| **License** | MIT | MIT |
| **Stars** | 5.9k | 48.2k |
| **Platform scope** | Apple only | Cross-platform |
| **Quantization** | No (Core ML handles optimization) | Q4/Q5/Q8 integer quantization |

---

## Key Conclusions for Transcriber App

### 1. WhisperKit is the clear winner for your use case
- Native Swift package, drop-in SPM dependency
- Core ML leverages ANE (more power-efficient than MLX GPU compute)
- Replaces your entire Python transcription pipeline (mlx-whisper)
- SpeakerKit replaces pyannote.audio for diarization
- Both MIT licensed

### 2. You do NOT need whisper.cpp if you use WhisperKit
- whisper.cpp serves a different audience (cross-platform C/C++ projects)
- No native Swift bindings, no diarization
- SwiftWhisper wrapper is thinly maintained
- The only advantage is quantized models (smaller, but Core ML has its own optimization)

### 3. SpeakerKit is viable but young
- Just open-sourced March 2026, API may evolve
- Claims DER parity with pyannote.audio — credible (Interspeech paper)
- 10x faster than pyannote on-device
- Takes `[Float]` arrays, works with files (not just live audio)
- Can merge speaker labels into WhisperKit transcription results
- Risk: it's the "free tier" — Argmax's commercial focus is now on Sortformer in Pro SDK

### 4. What WhisperKit would replace in your stack
- `transcribe.py` + mlx-whisper → `WhisperKit.transcribe(audioPath:)`
- pyannote.audio → `SpeakerKit.diarize(audioArray:)`
- Python conda environment → eliminated entirely
- `embed_python.sh` → eliminated
- The entire `TranscriptionRunner` Process launch → direct Swift async/await calls

### 5. Model flexibility comparison
- WhisperKit: choose any Whisper variant at init time, downloaded automatically
- whisper.cpp: same variants plus quantized versions (Q4_0, Q5_0, Q8_0) for size/speed tradeoff
- WhisperKit Pro SDK adds non-Whisper models (Nvidia Parakeet V3) — commercial only

### 6. Multilingual / per-segment language detection
- WhisperKit: supports language detection on multilingual models, can auto-detect
- whisper.cpp: same capability via Whisper's built-in language detection
- Neither has built-in per-segment language switching (this is a Whisper model limitation, not an inference engine limitation)

### 7. Risks and considerations
- WhisperKit is Apple-only — if you ever need Linux/server transcription, you'd need a separate solution
- SpeakerKit is very new; pyannote.audio has years of battle-testing
- Argmax's business model pushes toward Pro SDK for advanced features (streaming, Sortformer)
- Core ML model compilation can be slow on first run (ANE compilation)
- Your dual-stream architecture (system + mic WAV files) maps cleanly to WhisperKit file transcription
