# WhisperKit Research Notes — 2026-04-01

## 1. WhisperKit Open Source vs Pro SDK

### License
Open-source WhisperKit is **MIT licensed** (confirmed from LICENSE file).

### What's in Open Source (Basic Plan — Free)
- **WhisperKit** speech-to-text with all standard Whisper models (tiny through large-v3)
- File transcription (batch mode)
- Word-level timestamps
- Language detection (per 30s window)
- VAD-based chunking
- Core ML model loading from HuggingFace
- **SpeakerKit** (Pyannote 4 community-1 implementation) — open-sourced after Argmax moved to NVIDIA Sortformer for Pro. Announced in WhisperKit v0.12.0 release notes. Pyannote-based, Core ML optimized.

### What's Pro Only (requires Argmax SDK + API key)
- **WhisperKit Pro** — "frontier" models in `argmaxinc/whisperkit-pro` repo (gated on HuggingFace), described as "faster and more accurate than most cloud APIs"
- **Real-time streaming transcription** — the README explicitly says: "For real-time transcription server with full-duplex streaming capabilities, check out WhisperKit Pro Local Server." Streaming is **Pro only**.
- **SpeakerKit Pro** — uses NVIDIA Sortformer (not Pyannote), described as "evolution of Pyannote optimized for speed without compromising accuracy"
- **Combined diarization + transcription** pipeline (SpeakerKit Pro + WhisperKit Pro integration shown in code samples)
- Private Slack support (vs public Discord for free)

### Pricing (from takeargmax.com/pricing)
| Plan | Price | Includes |
|------|-------|----------|
| **Basic** | Free forever | Open-source WhisperKit (MIT), public Discord support |
| **Pro** | **$1.33**/device/month (monthly) or **$1.00**/device/month (yearly) | WhisperKit Pro + SpeakerKit Pro + private Slack support |
| **Enterprise** | Custom | Everything in Pro + implementation support + custom models + priority Slack + volume discounts |

**Pro Plan details:**
- $14 upfront for 14-day trial (30 device licenses during trial)
- After trial: minimum 1,000 device licenses/month commitment (~$1,000-$1,330/mo minimum)
- Unused licenses roll over (expire after 12 months)
- Per-device: unlimited usage, no rate limits, no concurrency limits
- "Active device" = any unique device that initialized the Pro SDK in a calendar month

### Integration Pattern
Pro requires `import Argmax` instead of `import WhisperKit`, with `ArgmaxSDK.with(ArgmaxConfig(apiKey: "ax_*****"))` initialization. Uses `WhisperKitPro` and `WhisperKitProConfig` classes. The API surface is similar — designed as a drop-in upgrade path.

---

## 2. Per-Segment Language Detection in WhisperKit

### What's Available (Open Source)

**Language detection exists and works per 30-second audio window**, but there is **no per-segment language field** in the output structs.

#### Data model hierarchy:
1. **`TranscriptionResult` / `TranscriptionResultStruct`** — has a single `language: String` field (top-level, one language for the whole result)
2. **`TranscriptionSegment`** — has `id`, `seek`, `start`, `end`, `text`, `tokens`, `tokenLogProbs`, `temperature`, `avgLogprob`, `compressionRatio`, `noSpeechProb`, `words` — **NO language field**
3. **`DecodingResult`** (internal per-window result) — has `language: String` and `languageProbs: [String: Float]` (full probability distribution across all languages)

#### How language detection works:
- In `TranscribeTask.swift`, when `options.language == nil` and `options.detectLanguage == true`, WhisperKit calls `textDecoder.detectLanguage()` for each 30-second encoder window
- This uses the Whisper language detection head (logits from the decoder's first token position)
- The detected language is stored in `DecodingResult.language` and `DecodingResult.languageProbs`
- **However**, the language is set at the `DecodingResult` level, not propagated down to individual `TranscriptionSegment` structs

#### Key limitation for multilingual audio:
- Language detection runs **per 30-second window** (Whisper's fundamental chunk size), not per segment
- If a single 30s window contains two languages, the detected language will be whichever has higher probability for that window
- The `TranscriptionSegment` struct has no `language` field — you cannot determine which language each segment was detected as from the public API
- The top-level `TranscriptionResult.language` is a single string, not per-segment

#### DecodingOptions language configuration:
- `language: String?` — set to nil for auto-detection, or a language code (e.g., "en") to force
- `detectLanguage: Bool` — must be true (along with language=nil) to enable auto-detection
- When language is forced, no detection runs and all segments use the specified language

### Comparison with mlx-whisper:
- mlx-whisper also detects language per 30-second window (same underlying Whisper architecture)
- Both share the same fundamental limitation: Whisper's language detection is per-encoder-window, not per-token or per-segment
- Neither provides true per-segment language tagging for code-switched audio within a single 30s window
- The difference: mlx-whisper's Python output includes `language` in the segment dict (via openai-whisper compatibility), while WhisperKit's Swift `TranscriptionSegment` struct omits it entirely

### Bottom Line:
To get per-segment language info from WhisperKit, you would need to either:
1. Fork and add a `language` field to `TranscriptionSegment`, propagating from the `DecodingResult`
2. Post-process: since each segment has `seek` (the 30s window offset), you could map segments back to their detection window and infer the language from the corresponding `DecodingResult`

Neither approach gives true intra-window multilingual detection — that's a Whisper model limitation, not a WhisperKit limitation.
