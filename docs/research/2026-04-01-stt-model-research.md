# Speech-to-Text Model Research for macOS Apple Silicon Transcription App

**Date:** 2026-04-01  
**Current setup:** mlx-whisper with `mlx-community/whisper-large-v3-mlx`  
**Primary languages:** FR, PT, ES, EN, plus KO, JA, TR, FI, SV

---

## 1. Whisper Model Family (OpenAI)

### Model Variants

| Model | Parameters | VRAM | Speed (rel. to large, on A100) | Multilingual |
|-------|-----------|------|-------------------------------|-------------|
| tiny | 39M | ~1 GB | ~10x | Yes (.en variant available) |
| base | 74M | ~1 GB | ~7x | Yes (.en variant available) |
| small | 244M | ~2 GB | ~4x | Yes (.en variant available) |
| medium | 769M | ~5 GB | ~2x | Yes (.en variant available) |
| large (v1) | 1550M | ~10 GB | 1x | Yes only |
| large-v2 | 1550M | ~10 GB | 1x | Yes only |
| large-v3 | 1550M | ~10 GB | 1x | Yes only |
| large-v3-turbo | 809M | ~6 GB | ~8x | Yes only |

### large-v3 vs large-v2

**large-v3** was trained on 1M hours of weakly labeled audio + 4M hours of pseudo-labeled audio (collected using large-v2). Uses 128 Mel frequency bins (vs 80 in v2). Added Cantonese language token. OpenAI claims **10-20% error reduction** over large-v2 across a wide variety of languages.

**However**, community reports indicate v3 can be **worse for certain non-English languages** compared to v2. Specific complaints:
- More hallucination-prone on some languages
- Worse timestamp accuracy in some scenarios
- For **your target languages** (FR, PT, ES): v3 is generally an improvement per OpenAI's own breakdown on Common Voice 15 and FLEURS datasets

**Recommendation for your use case:** large-v3 is the better choice for FR/PT/ES/EN. For KO/JA/TR/FI/SV, test both -- v3 should still be superior overall but individual edge cases exist.

### large-v3-turbo

**Architecture change:** Decoder layers reduced from 32 to 4 (same as tiny model's decoder), while keeping the full large-v3 encoder. Fine-tuned for 2 more epochs on the same multilingual transcription data as large-v3 (**excluding translation data** -- turbo is NOT trained for translation).

**Key characteristics:**
- ~8x faster than large-v3 (same speed tier as tiny, but with large encoder quality)
- 809M parameters (vs 1550M for full large)
- Across languages, performs similarly to **large-v2** (not v3)
- **Larger degradation** on some languages: Thai, Cantonese specifically called out
- Does NOT support translation task (only transcription)
- ~6 GB VRAM vs ~10 GB for full large

**For your use case:** Turbo is excellent if you only need transcription (not translation). The accuracy regression vs v3 is modest for European languages. **Best speed/quality trade-off if you want to move to streaming/real-time.**

MLX port available: `mlx-community/whisper-large-v3-turbo` (1.61 GB quantized, 18.6K monthly downloads -- more popular than the full v3 MLX port at 16.5K downloads).

### Known Whisper Shortcomings

1. **Hallucination:** Generates plausible but non-existent speech during silence or background noise. Distil-Whisper is specifically noted as being **less prone to hallucination** on long-form audio.
2. **Repetition:** Can get stuck in repetition loops, especially on long audio segments with repetitive content.
3. **Language confusion:** With multilingual models, can switch to wrong language mid-transcription, especially with code-switching speech.
4. **Timestamp accuracy:** Word-level timestamps are approximate. Turbo model may have slightly worse timestamps due to reduced decoder.
5. **30-second window:** Fixed context window -- long audio must be chunked, which can lose context at boundaries.

---

## 2. Alternative Models

### 2.1 whisper.cpp (ggml-org)

**What it is:** Pure C/C++ implementation of Whisper, no Python dependencies.

**Apple Silicon support (first-class citizen):**
- ARM NEON optimizations
- Accelerate framework
- **Metal GPU acceleration** (built-in)
- **Core ML support** (optional, can further accelerate)
- Integer quantization (Q4, Q5, Q8 etc.) -- further reduces memory and speeds up inference

**Key advantages:**
- No Python runtime needed -- could eliminate your embedded Python entirely
- Real-time streaming example built-in (`whisper-stream` using SDL2, samples every 500ms)
- VAD (Voice Activity Detection) support built-in
- Zero memory allocations at runtime
- Supports all Whisper model sizes in GGML format
- Swift/Objective-C bindings available

**Quality:** Identical to original Whisper (same weights, same architecture -- just different runtime). Quantized models may have very minor quality degradation.

**Performance on Apple Silicon:** Generally faster than Python Whisper on CPU. Metal GPU acceleration closes the gap with MLX. Specific benchmarks vary but community reports suggest comparable to or faster than mlx-whisper for most model sizes.

**Streaming capability:** Yes -- the `whisper-stream` example demonstrates real-time microphone transcription. Processes audio in chunks (configurable step size, typically 500ms-3s).

**Relevance to your app:** HIGH. Could enable:
1. Eliminating Python dependency entirely (native Swift/C++ integration)
2. Real-time/streaming transcription during recording
3. Smaller app bundle (no embedded Python + conda env)

### 2.2 WhisperKit (Argmax)

**What it is:** Swift framework for Whisper on Apple Silicon, using **Core ML** for inference. Native Swift API.

**Key features:**
- Pure Swift implementation
- Core ML optimized models (pre-converted, hosted on HuggingFace)
- Supports streaming from microphone (`--stream` flag)
- **SpeakerKit** companion: on-device speaker diarization using Pyannote v4 via Core ML
- **TTSKit** companion: text-to-speech
- Supports all Whisper model sizes
- macOS 13.0+ / iOS 16.0+

**Performance:** Core ML leverages the Neural Engine on Apple Silicon, which can be significantly faster than GPU for some model sizes. Argmax maintains benchmark data per Apple Silicon chip variant.

**SpeakerKit (diarization):** Runs Pyannote v4 segmentation and embedding models entirely on-device via Core ML. This could replace your pyannote.audio Python dependency.

**Relevance to your app:** VERY HIGH. Could enable:
1. 100% Swift implementation (no Python at all)
2. Native speaker diarization (SpeakerKit replaces pyannote.audio)
3. Streaming transcription via native Swift API
4. Leverages Neural Engine (potentially faster than MLX on GPU)
5. No conda/pip dependency management

### 2.3 faster-whisper (CTranslate2)

**What it is:** Reimplementation of Whisper using CTranslate2 inference engine. Up to 4x faster than openai/whisper with same accuracy, less memory.

**Apple Silicon support:** CTranslate2 supports CPU inference on Apple Silicon (ARM). **No Metal/MPS GPU acceleration** -- it is primarily optimized for NVIDIA CUDA GPUs. On Apple Silicon, it runs on CPU only.

**Benchmarks (GPU, for reference):**
| Implementation | Precision | Time (13min audio) | VRAM |
|---|---|---|---|
| openai/whisper | fp16 | 2m23s | 4708MB |
| faster-whisper | fp16 | 1m03s | 4525MB |
| faster-whisper (batch=8) | fp16 | 17s | 6090MB |
| faster-whisper | int8 | 59s | 2926MB |

**Relevance to your app:** LOW. Without Metal/MPS support, it will run on CPU only on Apple Silicon, which means mlx-whisper (which uses the GPU via MLX) will likely be faster. faster-whisper's strength is CUDA GPUs.

### 2.4 Distil-Whisper

**What it is:** Knowledge-distilled versions of Whisper. 5.8x faster, 51% fewer parameters, within 1% WER on OOD test data.

| Model | Params | Rel. Latency | Short-Form WER | Long-Form WER |
|-------|--------|-------------|----------------|--------------|
| large-v3 (teacher) | 1550M | 1.0x | **8.4** | 11.0 |
| distil-large-v3 | 756M | 6.3x | 9.7 | **10.8** |
| distil-large-v2 | 756M | 5.8x | 10.1 | 11.6 |
| distil-medium.en | 394M | 6.8x | 11.1 | 12.4 |
| distil-small.en | 166M | 5.6x | 12.1 | 12.8 |

**Critical limitation: ENGLISH ONLY.** All Distil-Whisper models are currently English-only. They are working with the community on other languages but nothing is released yet.

**Less prone to hallucination** than full Whisper on long-form audio.

**Supports speculative decoding** when paired with full Whisper: 2x speed-up while mathematically ensuring identical outputs to the teacher model.

**MLX availability:** distil-large-v3 has MLX ports on HuggingFace (mlx-community).

**Relevance to your app:** LOW for primary use case (multilingual). Could be useful as a secondary fast English-only mode. The hallucination reduction is interesting.

### 2.5 Moonshine (Moonshine AI, formerly Useful Sensors)

**What it is:** Purpose-built ASR models for real-time/streaming applications. Trained from scratch (not a Whisper derivative). Uses sliding-window self-attention for bounded latency.

**Models (v2, Feb 2026):**

| Model | WER | Parameters | MacBook Pro | Linux x86 | RPi 5 |
|-------|-----|-----------|-------------|-----------|-------|
| Moonshine Medium Streaming | 6.65% | 245M | **107ms** | 269ms | 802ms |
| Whisper Large v3 | 7.44% | 1550M | 11,286ms | 16,919ms | N/A |
| Moonshine Small Streaming | 7.84% | 123M | **73ms** | 165ms | 527ms |
| Whisper Small | 8.59% | 244M | 1,940ms | 3,425ms | 10,397ms |
| Moonshine Tiny Streaming | 12.00% | 34M | **34ms** | 69ms | 237ms |
| Whisper Tiny | 12.81% | 39M | 277ms | 1,141ms | 5,863ms |

**Stunning performance:** Moonshine Medium (245M params) achieves **6.65% WER** -- better than Whisper Large v3 (7.44% WER) at **1/6 the parameters** and **100x faster** on MacBook Pro (107ms vs 11,286ms). Claims state-of-the-art on standard benchmarks.

**Platform support:** Python, iOS, Android, macOS, Linux, Windows, Raspberry Pi, IoT devices. Has native macOS support.

**Language support:** Currently appears **English-focused**. The README and benchmarks are all English. Multilingual support is listed under "paid support for commercial customers who need... more languages." This is a significant limitation for your use case.

**Streaming:** Yes -- designed from the ground up for streaming. Ergodic streaming encoder with sliding-window self-attention achieves bounded, low-latency inference.

**Speaker diarization:** Mentioned as a capability in their API.

**Relevance to your app:** MEDIUM. Extraordinary speed and English accuracy, but **multilingual support is the blocker.** If they release multilingual models, this becomes the top recommendation for streaming transcription. Worth monitoring closely.

### 2.6 NVIDIA Canary

**What it is:** Multi-lingual multi-tasking ASR model based on FastConformer encoder + Transformer decoder.

**Canary-1B:** 1B parameters, supports:
- ASR in 4 languages: English, German, French, Spanish
- Translation: EN<->DE/FR/ES
- With/without punctuation and capitalization

**Evaluation results (Common Voice 16.1):**
- English: 7.97% WER
- German: 4.61% WER
- Spanish: 3.99% WER
- French: 6.53% WER

**Canary-1B-Flash:** Faster, more accurate variant available.

**Limitation:** Only 4 languages (EN/DE/FR/ES). Missing PT, KO, JA, TR, FI, SV.

**Apple Silicon:** Requires NVIDIA NeMo framework. Primarily designed for NVIDIA GPUs (CUDA). **No native Apple Silicon/Metal support.** Would need to run on CPU via PyTorch, which would be very slow for 1B parameters.

**Relevance to your app:** LOW. Limited language support, no Apple Silicon GPU acceleration.

### 2.7 NVIDIA Parakeet

**Parakeet TDT 0.6B v2 (English only):**
- 600M parameters, FastConformer-TDT architecture
- Excellent English WER: LibriSpeech clean 1.69%, other 3.19%
- Accurate word-level timestamps
- Automatic punctuation and capitalization
- RTFx of 3380 (very fast) -- but on NVIDIA GPU

**Parakeet TDT 0.6B v3 (Multilingual, NEW):**
- 600M parameters, extends v2 to **25 European languages**
- Supported: bg, hr, cs, da, nl, en, et, **fi**, **fr**, de, el, hu, it, lv, lt, mt, pl, **pt**, ro, sk, sl, **es**, **sv**, ru, uk
- Auto language detection
- Word-level and segment-level timestamps
- CC BY 4.0 license

**Parakeet v3 evaluation (English, Common Voice):**
- LibriSpeech clean: 1.93% WER
- LibriSpeech other: 3.59% WER

**Apple Silicon:** Same issue as Canary -- NeMo/CUDA-focused. No Metal support.

**Relevance to your app:** LOW despite good language coverage (covers FR, PT, ES, EN, FI, SV from your list). The lack of Apple Silicon GPU support is the deal-breaker. Also missing KO, JA, TR.

### 2.8 Meta SeamlessM4T v2

**What it is:** All-in-one multilingual multimodal translation model.
- 2.3B parameters
- 101 languages for speech input
- 96 languages for text input/output
- 35 languages for speech output
- Supports: S2ST, S2TT, T2ST, T2TT, ASR

**Covers ALL your target languages:** EN, FR, PT, ES, KO, JA, TR, FI, SV.

**Code-switching:** Designed for multilingual scenarios. The massively multilingual training should handle code-switching better than Whisper, though it's not explicitly designed for code-switching.

**Apple Silicon:** PyTorch-based. Can run on MPS (Metal Performance Shaders) but 2.3B parameters will be slow and memory-hungry. No MLX port exists.

**Quality:** Designed more for translation than pure ASR. For pure transcription quality in a single language, Whisper likely wins. Seamless shines when you need cross-lingual capabilities.

**Relevance to your app:** LOW-MEDIUM. Overkill for pure ASR. The 2.3B parameter count and lack of MLX optimization make it impractical for a desktop app. Interesting if you ever need real-time translation.

### 2.9 Meta MMS (Massively Multilingual Speech)

**What it is:** Wav2Vec2-based model fine-tuned for ASR in **1162 languages.** 1B parameters.

**Architecture:** Very different from Whisper. CTC-based (Connectionist Temporal Classification), not seq2seq. This means:
- No language model / decoder beam search by default
- Output is character-level
- No built-in punctuation or capitalization
- No translation capability

**Language switching:** Requires explicitly setting the language adapter. Cannot auto-detect or handle code-switching.

**Quality for major languages:** Generally **worse than Whisper** for well-resourced languages like EN/FR/ES/PT. MMS is designed for breadth (1000+ languages) not depth. It excels for low-resource languages where Whisper has no training data.

**Apple Silicon:** PyTorch via Transformers. Can use MPS but no MLX port.

**Relevance to your app:** LOW. Worse quality than Whisper for your target languages. CTC architecture means no punctuation/capitalization.

### 2.10 Deepgram Nova-2/3

**Cloud API only.** No local inference capability. Nova-3 claims best-in-class accuracy. Irrelevant for an on-device app unless you want to offer a cloud transcription mode.

### 2.11 AssemblyAI

**Cloud API only.** Universal-2 model claims competitive accuracy. Same limitation -- no local inference.

### 2.12 Google USM (Universal Speech Model)

**Not publicly available** for local inference. Powers Google's cloud ASR services. Published paper only. Cannot be used in local apps.

---

## 3. MLX-Specific Ecosystem

### Available MLX Whisper models (mlx-community on HuggingFace):

The MLX Whisper collection has **48 items** including all Whisper sizes:
- `mlx-community/whisper-tiny` through `whisper-large-v3-mlx`
- `mlx-community/whisper-large-v3-turbo` (1.61 GB, most downloaded: 18.6K/month)
- `mlx-community/whisper-large-v3-mlx` (16.5K downloads/month)
- Distil-Whisper variants in MLX format
- Various quantization levels

### Non-Whisper ASR models on MLX:

From the mlx-community collections page:
- **Qwen3-ASR:** Qwen's ASR models ported to MLX (NEW, 2025-2026)
- **Parakeet:** NVIDIA Parakeet ported to MLX
- **Sam Audio:** Audio models
- **Moonshine:** Not spotted in MLX community yet

### MLX vs PyTorch performance on M-series:

MLX is Apple's native ML framework, designed specifically for Apple Silicon unified memory architecture. Key advantages:
- **Unified memory:** No CPU<->GPU data transfer overhead
- **Lazy evaluation:** Computation graph optimization
- **Metal GPU:** Direct GPU utilization
- Generally **2-5x faster** than PyTorch MPS for transformer inference on Apple Silicon
- **Memory efficient:** Shares memory between CPU and GPU

---

## 4. Performance Benchmarks on Apple Silicon

### Approximate RTF (Real-Time Factor) on M-series chips:

Note: Exact numbers vary significantly by chip generation (M1 vs M4), audio length, and quantization.

| Runtime | Model | Approx. Speed (M2 Pro, 1min audio) |
|---------|-------|-----------------------------------|
| mlx-whisper | large-v3 | ~15-25s (0.25-0.4 RTF) |
| mlx-whisper | large-v3-turbo | ~3-5s (0.05-0.08 RTF) |
| mlx-whisper | medium | ~5-8s |
| whisper.cpp (Metal) | large-v3 | ~15-30s |
| whisper.cpp (Metal+Q5) | large-v3 | ~8-15s |
| WhisperKit (CoreML) | large-v3 | ~10-20s (Neural Engine) |
| Moonshine | medium | ~0.1s (streaming, per chunk) |
| faster-whisper | large-v3 (CPU only) | ~60-120s |

*These are approximate ranges based on community reports. Actual performance depends heavily on chip variant, audio characteristics, and configuration.*

### Memory usage:

| Model | FP16 Size | Quantized (Q4/Q5) |
|-------|----------|-------------------|
| large-v3 | ~3 GB | ~1.5-2 GB |
| large-v3-turbo | ~1.6 GB | ~0.8-1 GB |
| medium | ~1.5 GB | ~0.7-1 GB |
| small | ~0.5 GB | ~0.3 GB |
| Moonshine medium | ~0.5 GB | N/A |

---

## 5. Code-Switching

No mainstream open-source ASR model is specifically designed for intra-sentence code-switching. Current state:

1. **Whisper large-v3:** Can handle code-switching to some degree due to multilingual training, but tends to commit to one language per 30-second segment. It may misidentify the language when switching occurs.

2. **SeamlessM4T:** Best theoretical candidate due to massively multilingual training on 101 languages, but not optimized for local inference.

3. **MMS:** Requires explicit language adapter switching -- cannot handle code-switching at all.

4. **Academic work:** Papers exist on code-switching ASR (especially for Spanglish, Hinglish) but no production-ready models with broad language support.

**Practical approach for your app:** Use Whisper with language auto-detection per segment. For meetings with mixed-language speakers, the per-speaker diarization helps because each speaker typically uses one language consistently. Code-switching within a single speaker's utterance remains an unsolved problem.

---

## 6. Streaming/Real-time Capable Models

| Model/Runtime | Streaming Support | Latency | Notes |
|--------------|------------------|---------|-------|
| **Moonshine v2** | Native streaming | 34-107ms/chunk | Purpose-built, English only |
| **whisper.cpp** | Via `whisper-stream` | 500ms-3s chunks | Works well, all Whisper models |
| **WhisperKit** | `--stream` mode | Sub-second | Core ML, Swift native |
| **mlx-whisper** | Not built-in | N/A | Would need custom chunked implementation |
| **Whisper (PyTorch)** | Not built-in | N/A | 30s fixed windows |
| **faster-whisper** | Partial (VAD-based) | Segment-level | CPU only on Apple Silicon |

---

## 7. Recommendations for Your App

### Short-term (keep current architecture, incremental improvements):

1. **Switch to `mlx-community/whisper-large-v3-turbo`** for ~5-8x speed improvement with modest accuracy trade-off. Best bang-for-buck change. Same MLX pipeline, just swap the model string.

2. **Add turbo as default, keep large-v3 as "high quality" option** in settings. Let users choose speed vs accuracy.

### Medium-term (enable streaming transcription):

3. **Evaluate whisper.cpp** for streaming during recording. The C/C++ implementation with Metal GPU support could run in a background thread, processing audio chunks as they're captured. This would enable your "streaming transcription to unblock back-to-back meetings" idea.

4. **Evaluate WhisperKit** as an alternative to whisper.cpp. Native Swift, Core ML optimized, includes SpeakerKit for diarization. Could eliminate both Python dependencies (mlx-whisper AND pyannote.audio).

### Long-term (eliminate Python dependency):

5. **WhisperKit + SpeakerKit** is the most promising path to a 100% Swift app:
   - WhisperKit replaces mlx-whisper (transcription)
   - SpeakerKit replaces pyannote.audio (diarization)
   - No Python, no conda, no pip, no ffmpeg
   - Smaller app bundle
   - Faster startup
   - Native streaming support

### Models to monitor:

6. **Moonshine:** If they release multilingual models, the speed advantages are extraordinary. 100x faster than Whisper large-v3 on MacBook with competitive accuracy.

7. **Qwen3-ASR on MLX:** New entrant, worth evaluating quality for your languages.

8. **Parakeet v3 on MLX:** If the mlx-community port works well, covers FR/PT/ES/EN/FI/SV with excellent accuracy.

### What to avoid:

- **faster-whisper:** No Apple Silicon GPU support, would be a regression.
- **NeMo/Canary/Parakeet (native):** NVIDIA GPU focused, poor Apple Silicon story.
- **Cloud APIs (Deepgram, AssemblyAI):** Breaks your on-device privacy model.
- **MMS:** Worse quality for your languages, no punctuation, clunky language switching.

---

## 8. Summary Matrix

| Solution | Quality (multilingual) | Speed (Apple Silicon) | Streaming | No Python | Diarization | Maturity |
|----------|----------------------|----------------------|-----------|-----------|-------------|---------|
| **mlx-whisper large-v3** (current) | Excellent | Good | No | No | Via pyannote | High |
| **mlx-whisper large-v3-turbo** | Very Good | Very Good | No | No | Via pyannote | High |
| **whisper.cpp** | Excellent | Very Good | Yes | Yes (C++) | No built-in | High |
| **WhisperKit + SpeakerKit** | Excellent | Excellent | Yes | Yes (Swift) | Yes (CoreML) | Medium-High |
| **Moonshine** | English only | Extraordinary | Yes | Partial | Yes | Medium |
| **Distil-Whisper** | English only | Excellent | No | No | Via pyannote | High |
| **SeamlessM4T** | Good (101 langs) | Poor (2.3B) | No | No | No | Medium |
| **Canary/Parakeet** | Good (limited langs) | Poor (CUDA) | No | No | No | High |
