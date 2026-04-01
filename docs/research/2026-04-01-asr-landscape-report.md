# ASR Landscape Report for macOS Meeting Transcription

**Date:** 2026-04-01  
**Hardware:** Apple M5 Pro (48GB unified memory)  
**Context:** Evaluating ASR models and frameworks for Transcriber, a macOS menu bar app for meeting transcription with speaker diarization. Requirements include multilingual support (EN/FR/PT/ES/SV/FI/TR/KO/JA), on-device inference, and dual-stream audio (system + mic).

---

## 1. Hardware: Apple M-series Chips for ML Inference

### M5 Pro Specifications

| Component | Spec |
|-----------|------|
| CPU | 18-core (12P + 6E) |
| GPU | 20-core |
| Neural Engine (ANE) | 16-core |
| Memory Bandwidth | 307 GB/s |
| Unified Memory | 48 GB |

### ANE vs GPU vs CPU for Transformer Models

Apple Silicon provides three compute paths for ML inference:

- **ANE (Neural Engine):** Fixed-function accelerator optimized for power-efficient inference on small models. Excels at models under ~300M parameters. For larger models, it becomes **bandwidth-bound** -- Apple's own research paper confirms that ANE throughput degrades when models exceed ~500M parameters due to limited on-chip SRAM and the need to stream weights from main memory.

- **GPU:** Best for large autoregressive decoders. Whisper large-v3 has 1.5B parameters -- well above the ANE sweet spot. The GPU's higher memory bandwidth utilization and parallel compute make it the clear winner for these workloads. Direct Metal frameworks (MLX, whisper.cpp) outperform CoreML-managed GPU by avoiding runtime overhead.

- **CPU:** Only useful as a fallback. Slowest path for transformer inference.

### CoreML Compute Units

CoreML exposes four compute unit options:

| Option | Routes to | Best for |
|--------|-----------|----------|
| `.all` | ANE preferred, fallback to GPU/CPU | Small models (<300M) |
| `.cpuAndGPU` | GPU preferred, CPU fallback | Large models on Mac |
| `.cpuAndNeuralEngine` | ANE preferred, CPU fallback | Power-efficient mobile |
| `.cpuOnly` | CPU only | Debugging / compatibility |

### CoreML Runtime Overhead vs Direct Metal

CoreML introduces measurable overhead compared to direct Metal frameworks (MLX, whisper.cpp):

- **Operation scheduling:** CoreML's graph compiler performs op-by-op dispatch rather than fused kernel execution
- **No kernel fusion:** Cannot combine multiple operations into single GPU passes the way custom Metal kernels can
- **MPS vs custom kernels:** CoreML uses Metal Performance Shaders (MPS), which are general-purpose; MLX and whisper.cpp use hand-tuned Metal kernels optimized for transformer attention patterns
- **Model compilation:** CoreML models require ahead-of-time compilation (`.mlmodelc`), adding startup latency

The net effect: even when forcing CoreML to GPU (`.cpuAndGPU`), it remains approximately **3x slower** than MLX on the same hardware for Whisper large-v3.

---

## 2. Whisper Model Family

### Model Variants

| Model | Parameters | Relative Speed | English WER | Notes |
|-------|-----------|----------------|-------------|-------|
| tiny | 39M | 32x | ~7.6% | Fastest, lowest quality |
| base | 74M | 16x | ~5.7% | |
| small | 244M | 6x | ~4.3% | ANE sweet spot |
| medium | 769M | 2x | ~3.6% | |
| large-v2 | 1.5B | 1x | ~3.0% | Best multilingual (v2 era) |
| large-v3 | 1.5B | 1x | ~2.9% | Improved multilingual, some regressions |
| large-v3-turbo | 809M | ~8x vs large | ~3.0% | 4-layer decoder, same encoder |

### large-v3 vs large-v2

- **large-v3** improved on multilingual benchmarks overall but introduced regressions in some languages
- **large-v2** remains more reliable for certain language pairs
- Both share the same 1.5B parameter encoder; v3 updated training data and decoder

### large-v3-turbo

- Reduces the decoder from 32 layers to **4 layers** while keeping the full encoder
- Approximately **8x faster** than large-v3 with near-identical encoder quality
- Decoder quality slightly lower -- acceptable for most transcription use cases
- Same multilingual coverage as large-v3

### Known Shortcomings

1. **Hallucination:** Whisper generates text even on silence or noise, producing phantom words or repeated phrases
2. **Repetition:** The autoregressive decoder can enter loops, especially on low-quality audio or long silences
3. **Language confusion:** In multilingual audio, Whisper may switch language mid-output or apply wrong language decoding
4. **30-second window:** Input is chunked into 30s segments -- context does not carry across boundaries, causing sentence breaks and potential quality drops at boundaries
5. **Code-switching:** Language is detected once per 30s window, not per sentence -- a meeting with French and English speakers gets each segment classified as one or the other, never both

---

## 3. Frameworks Benchmarked

### 3.1 WhisperKit (CoreML)

**Repository:** argmaxinc/WhisperKit  
**Model format:** CoreML (.mlmodelc)  
**Architecture:** Separate CoreML models for encoder, decoder, mel spectrogram, and prefill

#### Key Findings

- **ModelComputeOptions** allows per-component ANE/GPU selection (e.g., encoder on GPU, decoder on GPU)
- **Default routes to ANE** -- this is actively harmful for large models on Mac hardware
- Even with `.cpuAndGPU` forced, still **3x slower than MLX** due to CoreML runtime overhead
- WhisperKit uses underscore naming: `large-v3_turbo` (not `large-v3-turbo`)
- **SpeakerKit** included for speaker diarization (same team)
- Memory footprint: ~500MB (lower than MLX due to CoreML memory management)

#### Benchmark Results (M5 Pro, large-v3-turbo)

| Audio File | Duration | ANE (default) | GPU (.cpuAndGPU) |
|------------|----------|---------------|-------------------|
| Gustavo | 17 min | 8m 04s | 7m 37s |
| Jon Interview | 38 min | 12m 58s | -- |

#### Hardware Utilization (WhisperKit, ANE mode)

| Component | Power Draw |
|-----------|-----------|
| ANE | 7,170 mW |
| GPU | 7 mW |

### 3.2 mlx-whisper (MLX / GPU)

**Repository:** ml-explore/mlx-examples  
**Model format:** MLX (safetensors + config)  
**Runtime:** Python (requires conda environment)

#### Key Findings

- Uses **direct Metal GPU** via custom kernels -- no CoreML intermediary
- **Lazy evaluation** and **zero-copy unified memory** access minimize overhead
- Uses whisper-large-v3 model (full, not turbo) and still outperforms WhisperKit with turbo
- Requires Python runtime (conda environment) -- cannot ship as single Swift binary
- Memory footprint: ~3.5 GB (model loaded directly into unified memory)

#### Benchmark Results (M5 Pro, large-v3)

| Audio File | Duration | Time |
|------------|----------|------|
| Gustavo | 17 min | 2m 23s |
| Jon Interview | 38 min | 3m 35s |

#### Hardware Utilization (mlx-whisper)

| Component | Power Draw |
|-----------|-----------|
| GPU | 12,795 mW |
| ANE | 0 mW |

### 3.3 FluidAudio (Parakeet TDT, CoreML)

**Repository:** FluidInference/FluidAudio  
**Model:** NVIDIA Parakeet TDT 0.6B (not Whisper)  
**Model format:** CoreML on ANE  
**Integration:** SPM package

#### Key Findings

- Uses **Parakeet TDT 0.6B** -- a CTC/TDT hybrid, not autoregressive like Whisper
- At 600M parameters, falls within the ANE sweet spot -- CoreML/ANE is appropriate here
- Claims **120-190x realtime** on M4 Pro (unverified on M5 Pro)
- **Built-in diarization** via LSEENDDiarizer -- no separate diarization pipeline needed
- Apache 2.0 license, no API key required
- **Language support: 25 European languages** including FR, PT, ES, EN, FI, SV
- **Missing languages: KO, JA, TR** -- significant gap for our multilingual requirements
- Benchmark results **pending**

### 3.4 SwiftWhisper / whisper.cpp (Metal GPU)

**Repository:** exPHAT/SwiftWhisper (Swift wrapper), ggerganov/whisper.cpp (core)  
**Model format:** GGML (supports Q4, Q5, Q8 quantization)  
**Integration:** SPM package

#### Key Findings

- C++ core with **Metal GPU acceleration** via custom kernels
- Same speed tier as mlx-whisper (direct Metal, no CoreML overhead)
- GGML quantization reduces model size and memory usage (Q5 large-v3 ~1.1GB vs ~3GB FP16)
- **No built-in diarization** -- would need separate pipeline
- Can produce a **single static binary** (no Python dependency)
- Benchmark results **pending** (expected to match mlx-whisper performance)

### 3.5 macOS 26 SpeechAnalyzer (Apple Native)

**Framework:** Speech.framework (new in macOS 26)  
**API:** `SpeechTranscriber` + `SpeechAnalyzer`

#### Key Findings

- Brand new in macOS 26, announced at WWDC 2025
- On-device inference, models auto-download via system
- Apple claims **2.2x faster than Whisper Large V3 Turbo**
- **No speaker diarization** -- Apple's own reference apps use FluidAudio for that
- Presets: `.transcription` (batch), `.progressiveLiveTranscription` (streaming)
- **Too new to fully evaluate** -- limited documentation, no third-party benchmarks
- Would raise minimum deployment target to macOS 26
- Benchmark results **pending**

### 3.6 Moonshine (English Only)

**Repository:** usefulmachines/moonshine  
**Parameters:** 245M  
**WER:** 6.65% (beats Whisper large-v3 at 7.44% on English benchmarks)

#### Key Findings

- Purpose-built for **streaming** transcription
- Extremely fast: **107ms per chunk** vs 11,286ms for Whisper (100x faster)
- **English only** -- multilingual version is commercial/paid
- Not viable for our multilingual requirements unless used as English-only fast path

### 3.7 Models Evaluated but Not Viable

| Model / Service | Reason for Exclusion |
|----------------|---------------------|
| faster-whisper | No Metal/MPS GPU support; CPU-only on Mac |
| NVIDIA Canary / Parakeet (standalone) | CUDA-focused; no Apple Silicon GPU path |
| Meta SeamlessM4T | 2.3B parameters; too heavy; no MLX port |
| Meta MMS | CTC-based; worse quality for major languages |
| Deepgram | Cloud-only |
| AssemblyAI | Cloud-only |
| Google USM | Not publicly available |
| Distil-Whisper | English only |

---

## 4. Multilingual and Code-Switching

### The Code-Switching Problem

No current ASR model handles **intra-sentence code-switching** well. A meeting where participants mix French and English within sentences will produce errors regardless of model choice.

**Whisper's limitation:** Language is detected once per 30-second window. If a French speaker says "Let's discuss le budget pour next quarter," Whisper classifies the entire 30s segment as either French or English, not both.

### fastText Post-Processing Approach

A practical workaround for code-switching:

1. Run initial transcription with Whisper (primary language auto-detected per segment)
2. Use **fastText language detection** on each output sentence
3. Identify sentences where detected language mismatches the segment's declared language
4. Re-transcribe those specific audio segments with the correct language forced

**Limitations:**
- Works for **Latin-script languages** (FR, PT, ES, EN, SV, FI, TR) where fastText can distinguish
- **Fails for CJK** (KO, JA) -- fastText needs sufficient text and CJK sentences may be too short or mixed with Latin text
- Adds processing time proportional to code-switching frequency

### WhisperKit Language Access

WhisperKit exposes `language` per `DecodingResult` but **not per segment** -- making it harder to implement fine-grained language detection from the decoder's perspective without post-processing.

---

## 5. Benchmark Results Summary

### Transcription Speed

| Framework | Model | Gustavo (17 min) | Jon Interview (38 min) | Realtime Factor |
|-----------|-------|-----------------|----------------------|-----------------|
| WhisperKit (ANE) | large-v3-turbo | 8m 04s | 12m 58s | ~2.9x RT |
| WhisperKit (GPU) | large-v3-turbo | 7m 37s | -- | ~2.2x RT |
| mlx-whisper | large-v3 | 2m 23s | 3m 35s | ~10.6x RT |

**mlx-whisper is 3.4x faster than WhisperKit GPU** while using a larger model (large-v3 vs large-v3-turbo).

### Hardware Utilization Comparison

| Metric | WhisperKit (ANE default) | mlx-whisper (GPU) |
|--------|------------------------|-------------------|
| ANE Power | 7,170 mW | 0 mW |
| GPU Power | 7 mW | 12,795 mW |
| Memory Usage | ~500 MB | ~3,500 MB |
| Compute Path | ANE (CoreML) | GPU (Metal, custom kernels) |

### Key Takeaway

The GPU path with direct Metal access (MLX, whisper.cpp) dramatically outperforms CoreML-managed inference, even when CoreML is forced to GPU. The CoreML runtime overhead accounts for approximately 3x of the performance gap.

---

## 6. Architecture Decision

### Current State

The app currently uses **WhisperKit + SpeakerKit** for a fully Swift, single-binary architecture. This is architecturally clean but 3.5x slower than the Python-based mlx-whisper alternative.

### Options Evaluated

| Option | Speed | Diarization | Languages | Binary | Status |
|--------|-------|-------------|-----------|--------|--------|
| **WhisperKit + SpeakerKit** (current) | 1x (baseline) | SpeakerKit | All Whisper langs | Single Swift binary | In production |
| **mlx-whisper + pyannote** (previous) | 3.5x | pyannote.audio | All Whisper langs | Requires Python | Proven, benchmarked |
| **whisper.cpp (SwiftWhisper)** | ~3.5x (est.) | None (need separate) | All Whisper langs | Single Swift binary | Pending benchmark |
| **FluidAudio (Parakeet TDT)** | TBD (claims 120x RT) | LSEENDDiarizer | 25 langs (no KO/JA/TR) | Swift SPM | Pending benchmark |
| **SpeechAnalyzer (macOS 26)** | TBD (claims 2.2x Turbo) | None (use FluidAudio) | TBD | Native framework | Pending evaluation |
| **MLX Swift** | ~3.5x (est.) | None (need separate) | All Whisper langs | Swift binary | Not yet mature for Whisper |

### Decision Matrix

The primary tension is **speed vs architecture simplicity**:

- **If speed is paramount:** mlx-whisper (Python) or whisper.cpp (Swift) offer 3.5x improvement
- **If single-binary Swift is paramount:** WhisperKit works but with significant speed penalty; whisper.cpp could close this gap
- **If diarization bundled matters:** FluidAudio includes diarization but lacks KO/JA/TR
- **If future-proofing matters:** SpeechAnalyzer is Apple's direction but too new and lacks diarization

### Pending Items

Before making a final architecture decision:

1. **Benchmark FluidAudio** on M5 Pro with our test files
2. **Benchmark whisper.cpp / SwiftWhisper** on M5 Pro with our test files
3. **Evaluate SpeechAnalyzer** when macOS 26 documentation matures
4. **Test FluidAudio diarization quality** vs pyannote.audio vs SpeakerKit

---

## 7. Future Considerations

### Streaming Transcription

Real-time transcription during recording would unblock back-to-back meetings (no waiting for post-recording processing). Candidates for streaming:

- **Moonshine:** Purpose-built for streaming, 100x faster than Whisper, but English only
- **SpeechAnalyzer `.progressiveLiveTranscription`:** Apple's native streaming preset
- **WhisperKit streaming mode:** Supports chunked processing but quality degrades
- **whisper.cpp real-time:** Has experimental streaming support

### CoreML Precompilation

CoreML models require compilation on first use, adding 30-60s startup latency. Options:

- Precompile at model download time and cache the `.mlmodelc`
- Ship precompiled models (increases app size but eliminates first-run delay)
- WhisperKit handles this automatically but the delay is still user-visible

### Model Storage Management

Multiple models consume significant disk space:

| Model | Approximate Size |
|-------|-----------------|
| Whisper large-v3 (MLX) | ~3.0 GB |
| Whisper large-v3 (CoreML) | ~3.2 GB |
| Whisper large-v3-turbo (CoreML) | ~1.6 GB |
| Whisper large-v3 (GGML Q5) | ~1.1 GB |
| Parakeet TDT 0.6B (CoreML) | ~1.2 GB |

A settings UI for model management (download, delete, select active model) would be necessary if supporting multiple engines.

### Settings UX for Model Switching

If the app supports multiple engines or models, the Settings UI needs:

- Model picker dropdown with download status indicators
- Download progress for models not yet cached
- Disk usage display per model
- Engine selection (WhisperKit / whisper.cpp / FluidAudio) with speed/quality tradeoff explanation
- Language coverage warnings (e.g., "FluidAudio does not support Korean")

---

## Appendix: Test Audio Files

| File | Duration | Content | Languages |
|------|----------|---------|-----------|
| Gustavo | 17 min | Interview, single speaker dominant | EN |
| Jon Interview | 38 min | Multi-speaker interview | EN |

---

*This report consolidates findings from benchmarking sessions conducted on 2026-04-01 using an Apple M5 Pro with 48GB unified memory running macOS 15.*
