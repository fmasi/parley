# ASR Ecosystem Monitoring

## Claude Cowork Prompt (set up as weekly or monthly)

Copy-paste this into Claude Cowork desktop:

---

You are monitoring the ASR (speech-to-text) ecosystem for developments relevant to a macOS Apple Silicon meeting transcription app. Search the web for news from the past month.

**Current stack:** WhisperKit (CoreML) + SpeakerKit for transcription/diarization. Evaluating: FluidAudio (Parakeet), whisper.cpp (SwiftWhisper), macOS 26 SpeechAnalyzer, mlx-whisper.

**Models & frameworks to track:**
- WhisperKit (argmaxinc) — new versions, compute unit improvements, CoreML performance fixes
- FluidAudio (FluidInference) — new Parakeet model versions, language support expansion, performance
- whisper.cpp (ggerganov) — Metal GPU improvements, new model support, Swift bindings
- Apple SpeechAnalyzer/SpeechTranscriber — macOS 26+ updates, new presets, diarization support
- Moonshine (Moonshine AI) — multilingual release status
- MLX ecosystem (apple/mlx, mlx-community) — new ASR models ported to MLX, mlx-swift ASR examples
- OpenAI Whisper — new model versions (v4?)
- Distil-Whisper — multilingual variants

**What matters most:**
- Performance benchmarks on M-series chips (especially M4/M5 Pro)
- CoreML runtime improvements that close the gap with MLX/Metal
- ANE optimization breakthroughs for large transformer models
- New models with better speed/quality tradeoff than Whisper large-v3-turbo
- Multilingual and code-switching improvements (FR, PT, ES, EN priority)
- Speaker diarization advances (on-device, CoreML)
- Streaming/real-time transcription capabilities

**Version tracking — flag if any of these release a new non-bugfix version:**
- WhisperKit (current: 0.18.0)
- FluidAudio (current: 0.13.4)
- SwiftWhisper (current: 1.2.0)
- Moonshine (current: v2, English only)
- mlx-whisper (note current version)

**Output format:**
1. **Headlines** — 3-5 most noteworthy items
2. **Details** — one paragraph per item with source links
3. **Version changes** — table of tracked frameworks with current vs new version, flag non-bugfix updates
4. **Recommendation** — should we re-run the engine benchmark? (yes/no with reason)

If nothing significant happened, say so briefly. Do not fabricate news.

---

## Running the Engine Benchmark (manual, when monitoring flags something interesting)

```bash
# Run all engines on a test recording
swift run --package-path tools/engine-benchmark EngineBenchmark ~/Documents/Recordings/2026-04-01/"130007-gustavo part 2.wav"

# Run specific engines only
swift run --package-path tools/engine-benchmark EngineBenchmark ~/Documents/Recordings/2026-04-01/"130007-gustavo part 2.wav" --engines fluid,speech

# Available engines: whisperkit, whisper-cpp, fluid, speech
```

Reports saved to `~/.audio-transcribe/benchmark/`.

Compare with previous reports to see if framework updates improved performance.

## Reference Documents

- Full research report: `docs/research/2026-04-01-asr-landscape-report.md`
- ANE vs GPU analysis: `docs/research/2026-04-01-ane-vs-gpu-whisper-performance.md`
- Model research: `docs/research/2026-04-01-stt-model-research.md`
