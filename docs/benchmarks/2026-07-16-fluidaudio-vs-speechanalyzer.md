# Engine comparison: FluidAudio vs SpeechAnalyzer (2026-07-16)

**Machine:** Apple M5 Pro, macOS 26.5.1, 48 GB.
**Data:** FLEURS `test` split, 50 utterances/language (read speech, native-speaker ground truth).
**Metric:** WER (word error rate); CER (character error rate) for ja/ko/zh.
**Harness:** `tools/engine-benchmark`, batch mode (per-file locale via `localeForLanguage`, SpeechAnalyzer run in a per-file subprocess).

## Results

| Language | FluidAudio | SpeechAnalyzer | Best |
|----------|:---:|:---:|:---:|
| English | **5.3%** | 7.4% | FluidAudio |
| Spanish | 3.4% | 3.3% | tie |
| French | **6.7%** | 8.5% | FluidAudio |
| Portuguese (pt-BR) | **4.6%** | 7.8% | FluidAudio |
| Japanese | — (unsupported) | **7.2%** | SpeechAnalyzer only |
| Korean | — (unsupported) | **4.0%** | SpeechAnalyzer only |
| Chinese (zh-CN) | — (unsupported) | **7.8%** | SpeechAnalyzer only |

SpeechAnalyzer additionally supports zh-HK, zh-TW, and Cantonese (yue-CN); FluidAudio/Parakeet v3 covers none of these.

## Conclusions

- **The engines are complementary, not competing.** FluidAudio (Parakeet) is the better default for
  European languages *and* auto-detects language. SpeechAnalyzer is the **only** engine for CJK, and
  its CJK accuracy is good (ko 4.0%, ja 7.2%, zh 7.8%). **Decision: keep both** — FluidAudio for
  European, SpeechAnalyzer for CJK.
- This **supersedes the 2026-04-02 numbers**, which showed SpeechAnalyzer *better* on Spanish and
  Portuguese. On a larger, current-model sample FluidAudio is better or tied on every European
  language. Treat single small runs cautiously — individual utterances swing widely.

## Correctness caveats found while running this

1. **The app's SpeechAnalyzer engine was mis-configured** — it defaulted a `nil` language to the
   *system* locale (`en_GB` here), so it transcribed non-English audio as English (Portuguese →
   gibberish). Fixed: `SpeechAnalyzerEngine` now resolves the locale explicitly, installs the
   on-device model, and fails loudly (`languageRequired` / `localeNotSupported` /
   `assetInstallFailed`) instead of silently mis-transcribing. See `SpeechAnalyzerLocale`.
2. **Apple CJK models DO install** — an initial run showed ko/zh failing with
   `SFSpeechErrorDomain Code=11`, but that was a **harness artifact**: batch mode spawns a fresh
   subprocess per file, so 50 concurrent `downloadAndInstall()` attempts for the same locale error
   out. Installing once (standalone) succeeds for ko-KR, zh-CN, ja-JP. The harness should install
   locale models once/serially (or retry) — tracked as a benchmark-tool bug.
3. **Open design piece:** SpeechAnalyzer cannot auto-detect language, so using it requires a
   language source. FluidAudio auto-detects European but does not cover CJK, so it can't route CJK
   either. Automatic language routing (without a manual per-recording setting) is unsolved and is
   tracked separately.

## Reproduce

```bash
# Ground-truth sample (isolated conda env; no host pip):
conda create -n asr-bench python=3.11 -y && conda run -n asr-bench pip install datasets soundfile
# fetch N FLEURS utterances/language -> WAVs named <code>-fleurs-NN.wav + ground-truth.json
#   (Audio(decode=False) + soundfile avoids the torchcodec dependency)
swift run --package-path tools/engine-benchmark EngineBenchmark \
    --batch "$HOME/Library/Application Support/Parley/benchmark/test-audio" \
    --ground-truth ".../ground-truth.json" --engines fluid,speech
```
