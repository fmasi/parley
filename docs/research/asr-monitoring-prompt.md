# ASR Ecosystem Monitoring

## Claude Cowork Prompt (set up as weekly or monthly)

Copy-paste this into Claude Cowork desktop:

---

You are monitoring the ASR (speech-to-text) ecosystem for developments relevant to a macOS Apple Silicon meeting transcription app. Search the web for news from the past month.

**Current stack:** Three swappable engines — Apple SpeechAnalyzer (default, macOS 26+), FluidAudio (Parakeet, CoreML/ANE), whisper.cpp (GGML, Metal GPU). Diarization via FluidAudio's OfflineDiarizerManager. WhisperKit/SpeakerKit were removed.

**Models & frameworks to track:**
- WhisperKit (argmaxinc) — new versions, compute unit improvements, CoreML performance fixes
- FluidAudio (FluidInference) — new Parakeet model versions, language support expansion, performance
- whisper.cpp (ggerganov) — Metal GPU improvements, new model support
- WhisperCppKit (Justmalhar/WhisperCppKit) — actively maintained Swift wrapper for whisper.cpp, supports 128-mel models (large-v3/turbo)
- Apple SpeechAnalyzer/SpeechTranscriber — macOS 26+ updates, new presets, **CRITICAL: monitor for speaker diarization/identification support** (confirmed missing as of macOS 26.4, FB15558523 filed)
- Moonshine (Moonshine AI) — multilingual release status
- MLX ecosystem (apple/mlx, mlx-community) — new ASR models ported to MLX, mlx-swift ASR examples
- OpenAI Whisper — new model versions (v4?)
- Distil-Whisper — multilingual variants

**Known issues to track for resolution:**
- SwiftWhisper (exPHAT) is DEAD since Aug 2023. WhisperCppKit replaced it. No need to monitor further.
- CoreML runtime overhead makes WhisperKit 3.5x slower than MLX GPU for same model. Monitor Apple CoreML improvements (affects FluidAudio too).
- **FluidAudio bus factor:** Core team is 2 people (Weng brothers). Monitor project health — commit frequency, responsiveness to issues. If activity drops, we need a diarization backup plan.
- **Apple SpeechAnalyzer diarization gap:** Apple confirmed no speaker ID support (FB15558523). Monitor every macOS beta/WWDC for this — if Apple adds diarization to SpeechAnalyzer, it becomes the obvious default for everything.

**Diarization-specific monitoring:**
- FluidAudio diarization pipelines: OfflineDiarizerManager (our current), LS-EEND, Sortformer — track quality improvements, new models
- Apple SpeechAnalyzer: watch for `SpeechTranscriber.ResultAttributeOption` additions related to speakers
- Any new Swift-native diarization packages (e.g., speech-swift by soniqo — 508 stars, created Feb 2026)
- Pyannote upstream: FluidAudio's offline pipeline is based on pyannote — monitor pyannote model improvements that FluidAudio might adopt

**FluidAudio integration features to track:**
- Qwen3 ASR (30+ languages, encoder-decoder) — watch for stability, benchmark comparisons vs Parakeet
- StreamingAsrManager / NemotronStreamingAsrManager — real-time transcription API maturity
- VadManager (Silero VAD) — pre-filtering silence before transcription
- Speaker embeddings (`TimedSpeakerSegment.embedding`) — cross-session speaker recognition potential
- TextNormalizer (ITN) improvements — more languages, phone number formatting, currency
- Custom vocabulary boosting (CTC word boost) — mentioned in docs, API surface unclear

**What matters most:**
- Performance benchmarks on M-series chips (especially M4/M5 Pro)
- CoreML runtime improvements that close the gap with MLX/Metal
- ANE optimization breakthroughs for large transformer models
- New models with better speed/quality tradeoff than Whisper large-v3-turbo
- Multilingual and code-switching improvements (FR, PT, ES, EN priority)
- **Speaker diarization advances (HIGH PRIORITY)** — on-device, CoreML, especially Apple-native solutions. If Apple adds diarization to SpeechAnalyzer, flag immediately.
- **Speaker embeddings / cross-session recognition** — FluidAudio exposes embeddings per speaker; track best practices for building persistent speaker databases
- Streaming/real-time transcription + diarization capabilities (LS-EEND, Sortformer advances)

**Version tracking — flag if any of these release a new non-bugfix version:**
- WhisperKit (current: 0.18.0)
- FluidAudio (current: 0.13.4)
- WhisperCppKit (current: check latest)
- SwiftWhisper — DEAD, replaced by WhisperCppKit, stop tracking
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

# Available engines: whisperkit, whisper-cpp, fluid, speech, mlx
```

Reports saved to `~/.audio-transcribe/benchmark/`.

Compare with previous reports to see if framework updates improved performance.

## Known Benchmark Issues

- **whisper-cpp**: Now uses WhisperCppKit (Justmalhar/WhisperCppKit) — actively maintained, supports 128-mel models. Replaced dead SwiftWhisper (exPHAT, stalled since Aug 2023).

## Reference Documents

- Full research report: `docs/research/2026-04-01-asr-landscape-report.md`
- ANE vs GPU analysis: `docs/research/2026-04-01-ane-vs-gpu-whisper-performance.md`
- Model research: `docs/research/2026-04-01-stt-model-research.md`
- Swift ASR landscape: `docs/research/2026-04-01-swift-asr-landscape.md`
