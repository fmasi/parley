# Native Swift ASR Landscape (April 2026)

Research into speech-to-text implementations that could replace the current Python
mlx-whisper + pyannote pipeline with a pure Swift solution.

---

## 1. WhisperKit (argmaxinc/WhisperKit)

- **URL:** https://github.com/argmaxinc/WhisperKit
- **Stars:** 5,894 | **Forks:** 537 | **Last active:** 2026-04-01
- **License:** MIT
- **Backend:** CoreML (not MLX Swift)
- **Platform:** macOS 13+, iOS 16+, watchOS, visionOS
- **Install:** SPM `from: "0.9.0"`

**What it provides:**
- **WhisperKit** -- Whisper speech-to-text via CoreML. All OpenAI Whisper model
  sizes supported (tiny through large-v3, distilled variants). Models auto-download
  from HuggingFace (`argmaxinc/whisperkit-coreml`). Supports streaming from
  microphone via CLI (`--stream`).
- **SpeakerKit** -- On-device speaker diarization via Pyannote v4 CoreML models.
  Can merge diarization results with WhisperKit transcriptions to produce
  speaker-attributed segments. Two strategies: `.subsegment` (word-level) and
  `.segment`.
- **TTSKit** -- Text-to-speech (Qwen3 TTS models, 0.6B and 1.7B).
- **Local Server** -- OpenAI-compatible API server with SSE streaming.
- Custom fine-tuned models supported via `whisperkittools`.

**API example (transcription + diarization):**
```swift
import WhisperKit
import SpeakerKit

let whisperKit = try await WhisperKit()
let speakerKit = try await SpeakerKit()

let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: "audio.wav")
let transcription = try await whisperKit.transcribe(audioArray: audioArray)
let diarization = try await speakerKit.diarize(audioArray: audioArray)

let speakerSegments = diarization.addSpeakerInfo(to: transcription)
for group in speakerSegments {
    for segment in group {
        print("\(segment.speaker): \(segment.text)")
    }
}
```

**Assessment:** Most mature option. Directly replaces both mlx-whisper AND pyannote
in a single Swift package. CoreML backend means Apple Neural Engine acceleration.
Active development, large community. The combined WhisperKit + SpeakerKit API is
almost a drop-in replacement for the current Python pipeline.

---

## 2. FluidAudio (FluidInference/FluidAudio)

- **URL:** https://github.com/FluidInference/FluidAudio
- **Stars:** 1,778 | **Forks:** 244 | **Last active:** 2026-04-01
- **License:** MIT
- **Backend:** CoreML (ANE-optimized, avoids GPU/MPS entirely)
- **Platform:** macOS, iOS
- **Install:** SPM `from: "0.12.4"` or CocoaPods

**What it provides:**
- **ASR:** Parakeet TDT models (NVIDIA-derived, not Whisper). Two variants:
  - `parakeet-tdt-0.6b-v3-coreml` -- multilingual (25 European languages)
  - `parakeet-tdt-0.6b-v2-coreml` -- English-only, highest recall
- **Real-time streaming** via `SlidingWindowAsrManager` with cancellation support
- **Speaker diarization** (Pyannote segmentation + embedding models)
- **VAD** (voice activity detection, Silero-based)
- **TTS** (Kokoro, PocketTTS, Silero models)
- **Performance:** ~190x real-time on M4 Pro (1 hour audio in ~19 seconds)

**Ecosystem:** Used by Voice Ink, Spokenly, Slipbox, Whisper Mate, and many other
shipping macOS/iOS apps. Also has React Native and Rust wrappers.

**Assessment:** Strong alternative to WhisperKit. Uses Parakeet (not Whisper) which
may have different accuracy characteristics. ANE-only execution is very power
efficient. Streaming support is more mature than WhisperKit's. Has diarization
built in. The fact that many production apps ship with it is a strong signal.
Not Whisper-based, so model compatibility with existing mlx-community weights
would not apply.

---

## 3. whisper.cpp + Swift (ggerganov/whisper.spm)

- **URL:** https://github.com/ggerganov/whisper.spm
- **Stars:** 190 | **Forks:** 30 | **Last active:** 2026-02-28
- **Backend:** C/C++ with Metal acceleration
- **Install:** SPM package wrapping whisper.cpp as C library

**What it provides:**
- Raw C API for Whisper inference, exposed to Swift via SPM
- Metal shader acceleration on Apple Silicon
- All Whisper model sizes in GGML format
- Streaming support (whisper.cpp has real-time mode)
- No diarization (would need separate solution)

**Other Swift wrappers for whisper.cpp:**
- `Justmalhar/WhisperCppKit` (1 star) -- XCFramework wrapper + CLI + model downloader
- `andrii-rubtsov/whisper-cpp-swift` (0 stars) -- pre-built XCFramework for macOS
- `abcgco/whisper-spm` (0 stars) -- SPM wrapper for XCFramework v1.8.3
- Several example apps: `swift-whisper.cpp-transcription`, `LocalWhisper`, `Whispr`,
  `VaulType`, `HTKit`

**Assessment:** Viable but requires writing Swift wrapper code around C API. No
built-in diarization. whisper.cpp is battle-tested and very performant, but the
Swift integration story is rougher than WhisperKit or FluidAudio. Best for cases
where you want maximum control over the inference pipeline.

---

## 4. MLX Swift for ASR -- Current State

### mlx-swift (apple/ml-explore/mlx-swift)
- **Stars:** 1,700 | General-purpose ML framework (tensors, neural network layers)
- Provides `MLX`, `MLXNN`, `MLXOptimizers`, `MLXRandom`
- Can theoretically implement any model architecture in Swift
- **No audio/speech examples or libraries exist**

### mlx-swift-examples (ml-explore/mlx-swift-examples)
- **Stars:** 2,476
- Contains: LLM chat, VLM, Stable Diffusion, MNIST, LoRA training
- **No ASR/audio/speech examples whatsoever**
- Reusable libraries: `MLXLLM`, `MLXVLM`, `MLXEmbedders` -- no audio equivalent

### mlx-swift-audio (Adamiito0909/mlx-swift-audio)
- **Stars:** 5 | Appears to be a low-quality/SEO project
- Claims TTS + STT but ships as a zip download, not a library
- **Not usable as a dependency**

### Can mlx-swift load MLX Python model weights?
- mlx-swift mirrors all MLX Python capabilities including safetensors loading
- In theory, you could reimplement Whisper architecture in Swift using `MLXNN`
  and load mlx-community weights
- **Nobody has done this.** You would need to port the entire Whisper model
  architecture (encoder + decoder + audio preprocessing) to Swift manually.
- The `mlx-swift-lm` library does this for LLMs -- an equivalent
  `mlx-swift-audio` library does not exist from Apple.

**Assessment:** MLX Swift has no ASR story. Building one would mean reimplementing
Whisper from scratch in Swift using MLXNN layers. This is a multi-week project
with no community precedent.

---

## 5. macOS 26 Native Speech APIs (Apple)

- **SpeechAnalyzer / SpeechTranscriber** -- New frameworks in iOS 26 / macOS 26
- Used by FluidInference/swift-scribe (318 stars) as the transcription backend
- Apple's own on-device model, presumably very high quality
- **Requires macOS 26+** (beta as of April 2026)
- No public documentation yet on model capabilities, language support, or
  whether it exposes timestamps/word-level alignment
- Unknown whether it provides diarization

**Assessment:** Worth monitoring. If Apple ships a high-quality on-device ASR
framework in macOS 26, it could eventually be the simplest path. But it is too
new and undocumented to evaluate properly. The macOS 26 minimum deployment
target is also a constraint.

---

## 6. Apple SFSpeechRecognizer (existing)

- Available since macOS 10.15
- On-device mode available since iOS 17 / macOS 14
- Quality is mediocre compared to Whisper
- No speaker diarization
- Limited language support for on-device mode
- **Not competitive** with Whisper/Parakeet for meeting transcription

---

## Summary Comparison

| Solution | Stars | Backend | Diarization | Streaming | Maturity |
|---|---|---|---|---|---|
| **WhisperKit** | 5,894 | CoreML | Yes (SpeakerKit) | Yes | Production-ready |
| **FluidAudio** | 1,778 | CoreML (ANE) | Yes | Yes (sliding window) | Production-ready |
| **whisper.cpp/SPM** | 190 | C++ + Metal | No | Yes | Stable but raw |
| **MLX Swift** | 1,700 | MLX | No ASR exists | N/A | Not applicable |
| **macOS 26 APIs** | N/A | Apple native | Unknown | Unknown | Too early |
| **SFSpeechRecognizer** | N/A | Apple native | No | Yes | Not competitive |

## Recommendation

**WhisperKit + SpeakerKit** is the strongest candidate for replacing the Python
pipeline. It provides:
1. Whisper inference in Swift via CoreML (same models, similar quality)
2. Speaker diarization via SpeakerKit (replaces pyannote)
3. Combined transcription+diarization API
4. SPM package, production-proven (5.9k stars)
5. Microphone streaming support

**FluidAudio** is a strong second choice, especially if Parakeet's accuracy proves
equal or better than Whisper for meeting transcription. Its ANE-only execution
and streaming support are advantages.

Both eliminate the Python dependency entirely and remove the need for embedded
conda environments, ffmpeg, and HuggingFace token management.
