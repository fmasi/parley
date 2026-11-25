# CJK engines and automatic language ID (2026-11-24, #339)

**Machine:** Apple M5 Pro, 48 GB, **macOS 27.2** (Darwin 27.2). **Under load:** other agents were building and
testing on this Mac throughout (load average 25 to 38), so every timing below is an upper bound, and the relative
order of engines matters more than the absolute RTFx.
**Data:** FLEURS `test` split, the first 50 utterances of ja_jp, ko_kr and cmn_hans_cn (the same 50 as 2026-07-16:
SpeechAnalyzer reproduces that report to within 0.1 pp), plus the first 20 of en_us, fr_fr, es_419, pt_br, de_de,
it_it and yue_hant_hk for language ID. 290 clips, 5 to 40 s each, one language per clip, read speech.
**Metric:** CER on NFKC-normalised text with all punctuation, symbols and spaces removed and Chinese folded to
Simplified (OpenCC t2s) on both sides. Corpus CER (edits / reference characters); the per-clip mean, which the
2026-07-16 report used, is given for SpeechAnalyzer.
**Harness:** `tools/engine-benchmark/cjk` (FluidAudio 0.17.7, the version Parley shipped when this ran; WhisperKit 0.18.0), one
engine per process. Reproduce at the end.

## Licences first

| Model | Licence | Redistribution in a paid AGPL binary |
|---|---|---|
| Parakeet TDT Japanese (`nvidia/parakeet-tdt_ctc-0.6b-ja`, FluidInference CoreML) | CC-BY-4.0 | Fine, with attribution (as Parakeet v3 today) |
| Cohere Transcribe 03-2026 (`CohereLabs/…`, FluidInference q8) | Apache-2.0 | Fine. The upstream repo is gated (accept terms); the CoreML conversion is not |
| SenseVoiceSmall (FunAudioLLM; FluidInference CoreML) | FunASR Model Licence v1.1 ("other") | Allowed: use, copy, modify and share with attribution and the model name kept. Not OSI. Two clauses to read with a lawyer: the licence terminates automatically on "denigration" of the model, and revisions published upstream "take effect automatically". Not a hard block; a risk for a product that ships it |
| Paraformer-large zh | `funasr/paraformer-zh` says Apache-2.0; FluidInference's conversion says "other", pointing at the FunASR model licence | Ambiguous: treat as the FunASR licence above |
| Whisper base/small/tiny (OpenAI weights, argmaxinc WhisperKit CoreML) | MIT (weights and WhisperKit) | Fine |
| Apple SpeechAnalyzer | OS component, nothing shipped | n/a |

Nothing blocks redistribution outright. SenseVoice and Paraformer carry the only non-standard terms.

## CER, ja / ko / zh

| Engine | Size on disk | ja | ko | zh | Notes |
|---|---|:---:|:---:|:---:|---|
| **Apple SpeechAnalyzer** (Parley's preset) | 0 (OS) | 6.8 (mean 7.2) | 4.2 (mean 3.9) | 9.8 (mean 7.7) | Needs the locale. Reproduces 2026-07-16 |
| **Cohere Transcribe q8** | 2.1 GB (enc 1.8 GB) | **3.0** | 5.5 | 12.3 | Language passed explicitly. First clip 110 s (ANE compile), **max RSS 15 GB** during it |
| **Parakeet TDT ja** | 0.6 GB | 10.3 | – | – | Japanese only. Fastest (RTFx ≈ 99) |
| SenseVoiceSmall fp16 (FluidAudio default) | 0.45 GB | 18.1 | 18.7 | 30.2 | **Blank output on 20 of 150 CJK clips** (31 of 290 overall), see below. Without the blank clips: ja 9.0, ko 7.7, zh 12.6 |
| SenseVoiceSmall int8 | 0.23 GB | 18.2 | 18.8 | 30.2 | Same blank clips as fp16 |
| SenseVoiceSmall fp16, with ITN | 0.45 GB | 18.0 | 18.8 | 28.1 | ITN changes numerals only; the blanks remain |
| SenseVoiceSmall fp32, CPU | 0.9 GB | 8.7 | 8.4 | 11.4 | No blank clips: the blanks are an ANE fp16/int8 artefact. FluidAudio 0.17.7 cannot run this path (it pads to fp16's buckets, the fp32 export takes a fixed 1800 frames); the harness drives it directly. RTFx ≈ 5 (CPU, with the harness's plain argmax) |
| Paraformer-large zh (fp16 ANE, int8 ANE, fp32 CPU) | 0.42 GB fp16 | – | – | **broken** | ANE: the same garbage string for every clip; CPU: empty strings. Not usable in FluidAudio 0.17.7 on macOS 27.2 |
| SenseVoiceSmall, Cantonese (yue_hant_hk, 20 clips) | | | | yue 8.2 (fp32: 3.3) | The only engine here with a Cantonese result |

Speed under load (steady state, after the first clip): SpeechAnalyzer RTFx 51, Parakeet-ja 99, SenseVoice 16 to 19,
Cohere 13. Memory: max RSS SenseVoice 2.0 to 2.4 GB, Paraformer 1.3 to 1.5 GB, Parakeet-ja 0.7 GB, Cohere 15 GB peak
during its first-load compile; SpeechAnalyzer runs out of process (21 MB here). `phys_footprint` does not count
ANE-resident weights, so RSS is the better guide; none of this was measured on the M1 Air target.

**Findings.**
1. SpeechAnalyzer stays the best all-round CJK engine (ko best by a margin, zh best, ja good). Cohere is better on
   Japanese (3.0 vs 6.8) but worse on ko and zh, needs the language too, is 2 GB and peaked at 15 GB on first load:
   not an M1 Air engine.
2. SenseVoice in FluidAudio 0.17.7 silently returns **empty text** for about 1 clip in 9 on its ANE paths (fp16
   and int8, the same clips). That is the exact failure Parley exists to prevent; it is disqualifying as an ASR engine
   until fixed upstream. Its fp32 CPU path has no blanks but still trails SpeechAnalyzer on all three languages (ja 8.7, ko 8.4, zh 11.4) at a
   fifth of the speed. Its one strength is Cantonese (3.3 % on fp32).
3. Paraformer does not work at all here. Parakeet-ja is good but Japanese only.

## Language ID

SenseVoice's tag is one of `zh, en, yue, ja, ko, nospeech` (the model card's "50+ languages" is SenseVoice-Large;
Small knows five). Whisper LID (WhisperKit `detectLanguage`, first 30 s) knows 99.

| Clips | SenseVoice fp16 tag | Whisper tiny | Whisper base | Whisper small | Whisper base, first 5 s | first 3 s |
|---|---|---|---|---|---|---|
| ja / ko / zh (150) | 128 correct (2 Mandarin tagged `yue`), **20 blank (no tag)** | 150/150 | 150/150 | 150/150 | 143/150 | 113/150 |
| en (20) | 16, 4 blank | 20/20 | 20/20 | 20/20 | 20/20 | 20/20 |
| fr / es / pt / de / it (100) | 0 (no tag for them): `en` 74, `nospeech` 14, a CJK tag 5, blank 6, 1 refused (> 30 s) | 100/100 | 100/100 | 100/100 | 95/100 | 84/100 |
| yue (20) | 19 `yue`, 1 blank | `zh` 20 | `zh` 19, `vi` 1 | `zh` 20 | `zh` 18 | `zh` 15 |
| Wrong side of CJK / not-CJK, all 290 | 5 European clips tagged CJK, plus 31 blank | 0 | 1 (a Cantonese clip tagged `vi`) | 0 | 6 | 38 |

Load and cost: Whisper base 0.14 GB, about 0.07 s per clip under load, max RSS 0.27 GB; tiny (0.07 GB) is as accurate on this
set; small is 0.46 GB.

**Findings.**
1. Whisper LID is perfect on clean read speech with 8+ s of audio, at every size, across CJK and European. It needs
   speech, not seconds of file: 5 s windows drop to 95 %, 3 s to about 80 % (FLEURS clips open with silence).
2. SenseVoice cannot be the language source: no European tags, 1 clip in 9 blank on the ANE path, and 5 % of
   European clips tagged CJK (6 % on fp32, which has no blanks and tags 148 of 150 CJK clips right).
3. Neither tells pt-BR from pt-PT, or Cantonese from Mandarin (Whisper tags Cantonese `zh`). Dialect is not
   something an off-the-shelf LID gives. It matters only where the ASR needs a locale (SpeechAnalyzer); Parakeet v3
   needs none.
4. Apple has no spoken-language ID: the macOS 27.2 SDK's `SpeechDetector` is speech/no-speech only.

## Recommendation (#147, #223)

- **Automatic language source: Whisper LID** (tiny or base through WhisperKit, MIT, 0.07 or 0.14 GB, downloaded at
  Setup like the other models). It is decoupled from both ASR engines, which #147 asked for. Run it on the speech
  VAD finds, not on the chunk's first 30 s: several windows of at least 8 to 10 s of speech per chunk per channel,
  majority vote, and treat a low-confidence or split vote as "unknown".
- **Routing per channel, decided per chunk, sticky per recording.** The two streams are independent (pt-BR mic,
  pt-PT remote; a Japanese caller and a European user), so each channel gets its own decision. A chunk whose vote
  agrees keeps the channel's language; a change needs a confident vote, so one noisy chunk never flips engines.
- **Engines:** Parakeet v3 (default) for every language it covers, with the detected language passed as v3's
  `language:` hint (`TokenLanguageFilter`). **SpeechAnalyzer for ja / ko / zh** with the detected locale. No
  FluidAudio-native CJK engine is ready: SenseVoice blanks clips, Paraformer is broken, Cohere is too heavy for the
  M1 Air, Parakeet-ja covers one language. Re-test SenseVoice when FluidAudio fixes its ANE path; Parakeet-ja is the
  candidate to revisit if Japanese accuracy or a non-Apple path matters.
- **Unknown or unsupported language** (LID unsure, or a language neither engine has): transcribe with Parakeet and
  record a processing issue saying the language was not identified; never a silent wrong-language transcript.
- **Locale variant:** Whisper's `zh` → `zh_CN` (Mandarin; Cantonese recordings would need a user hint or a
  Cantonese-aware LID), `pt` → Parakeet (no locale needed).

Part of #223 does not wait for this: with the #223 notice fix that came with this report, a chunked recording whose engine failed
reads "Transcription failed — speech recognition did not work" (nothing transcribed) or "Transcription incomplete —
speech recognition failed on N chunks", never "Transcription Complete".

## Decisions for the owner

1. Whisper LID as the language source (adds WhisperKit as an app dependency and a ~0.1 GB Setup download), or a
   different standalone LID.
2. Per-channel routing with a sticky per-recording decision, as above.
3. Whether an existing install with `engine: speech_analyzer` in config.json should be moved to FluidAudio at launch
   until routing lands (today it records, and every transcript now says "Transcription failed").
4. Cohere: not for the M1 Air tier; worth a line only if a Japanese-accuracy tier on bigger Macs is ever wanted.
5. SenseVoice: report the ANE blank-output bug and the fp32 bucket mismatch to FluidAudio upstream (and Paraformer).

## Reproduce

```bash
conda create -n cjk-bench python=3.11 -y
conda run -n cjk-bench python -m pip install pyarrow soundfile numpy huggingface_hub opencc-python-reimplemented
D=<scratch dir>
HF_TOKEN=... conda run -n cjk-bench python -I tools/engine-benchmark/cjk/fetch-fleurs.py $D/audio $D/parquet \
    ja_jp:50 ko_kr:50 cmn_hans_cn:50 en_us:20 fr_fr:20 es_419:20 pt_br:20 de_de:20 it_it:20 yue_hant_hk:20
swift build -c release --package-path tools/engine-benchmark/cjk
B=tools/engine-benchmark/cjk/.build/release/CJKBench
$B --engine sensevoice --gt $D/audio/ground-truth.json --out $D/sensevoice.jsonl   # one engine per process
#   sensevoice-int8 | sensevoice-itn | sensevoice-fp32 | paraformer | paraformer-int8 | paraformer-cpu
#   parakeet-ja (--langs ja_jp) | speech (--langs ja_jp,ko_kr,cmn_hans_cn)
#   cohere --cohere-dir <FluidInference/cohere-transcribe-03-2026-coreml>/q8
#   whisper-lid:openai_whisper-base | whisper-lid@5:openai_whisper-base (first 5 s)
conda run -n cjk-bench python -I tools/engine-benchmark/cjk/score.py $D/audio/ground-truth.json $D/*.jsonl
```

The FluidAudio models land in `~/Library/Application Support/FluidAudio/Models` (beside Parley's own), WhisperKit's in
`~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`, and SpeechAnalyzer installs the ja/ko/zh locales
system-wide. Delete them after a run if they are not wanted.
