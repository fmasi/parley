# ASR models: v3 `.int8` vs v3 `.int8V2` (Encoder_v2) vs Parakeet Ultra (2026-11-24)

For [#350](https://github.com/fmasi/parley/issues/350) (Encoder_v2) and
[#338](https://github.com/fmasi/parley/issues/338) (Parakeet Ultra). Background:
[docs/fluidaudio-evaluation-2026-10.md](../fluidaudio-evaluation-2026-10.md) §3.1. Previous report:
[2026-07-16](2026-07-16-fluidaudio-vs-speechanalyzer.md).

**Machine:** Apple M5 Pro, 48 GB, macOS 27.2.1. **FluidAudio 0.17.7** (the app's version).
**Timings were taken under heavy load** (other agents compiling; load average 11 → 43 on 18 cores).
**WER is the primary result. RTFx and load time are marked "under load, re-measure idle".**

## Method

- **Configurations**, as `AsrModels.load(version:encoderPrecision:)` names them:
  - `v3-int8`: `.v3`, `.int8` (Parley today: `Encoder.mlmodelc`, the 6-bit LUT encoder)
  - `v3-int8v2`: `.v3`, `.int8V2` (`Encoder_v2.mlmodelc`, int8 per-channel linear, #350)
  - `ultra`: `.ultra` (moondream post-training of v3, int8-linear encoder, #338)
- **Path:** the app's own. One `AsrManager`, then for each file a fresh `TdtDecoderState` and
  `transcribe(url, decoderState:, language: nil)`. That is the URL overload, which goes disk-backed for
  long files exactly as a recording chunk does. No ITN: the hypothesis is FluidAudio's raw text, the same
  for every configuration.
- **Data:**
  - FLEURS `test`, en_us / es_419 / fr_fr / pt_br (the European languages of the 2026-07-16 report). Two
    samples: the first 50 utterances per language (the July sample), and the **whole test split**
    (en 647, es 908, fr 676, pt 919 utterances; 10.1 h). The whole split is the decision set: on 50
    utterances (~1,200 words) a 0.3-point move is 3 or 4 words.
  - AMI **ES2004a** Mix-Headset (17.5 min, the diarization fixture).
  - AMI **ES2010c** Mix-Headset (30.6 min; the "one ~30-minute file").
  - AMI references come from the manual word annotations (`ami_public_manual_1.6.2`): all speakers' words,
    sorted by start time.
- **WER:** the harness normalisation (lowercase, punctuation except `'` to space). Corpus WER is total
  edits over reference words. Numbers are not normalised (`twenty five` vs `25` counts as an error), which
  matters for Ultra (see below).
- **Memory:** `/usr/bin/time -l` "peak memory footprint" of the benchmark process, one process per
  configuration and data set.
- **Harness:** `tools/engine-benchmark/run-asr-model-bench.sh` (new target `AsrModelBench`, plus
  `fetch-fleurs.py`, `ami-reference.py` and `analyze-asr-model-bench.py`). Models go to a benchmark-only
  folder, never the app's FluidAudio cache.

## WER

| Set | Ref words | v3-int8 | v3-int8v2 | ultra |
|---|---:|---:|---:|---:|
| **FLEURS English** (647 utt.) | 14,465 | 5.92% | 5.76% | **5.36%** |
| **FLEURS Spanish** (908) | 23,314 | 4.72% | 4.23% | **3.17%** |
| **FLEURS French** (676) | 17,151 | 6.92% | 7.02% | **6.19%** |
| **FLEURS Portuguese** (919) | 21,464 | 5.03% | 4.78% | **4.21%** |
| AMI ES2004a (17.5 min) | 2,653 | **17.98%** | 18.17% | 19.60% |
| AMI ES2010c (30.6 min) | 5,407 | 17.46% | 16.72% | **16.37%** |
| *FLEURS en, first 50* | 1,070 | 5.05% | 5.33% | 5.05% |
| *FLEURS es, first 50* | 1,259 | 3.34% | 3.18% | 2.62% |
| *FLEURS fr, first 50* | 1,288 | 6.99% | 7.07% | 6.83% |
| *FLEURS pt, first 50* | 1,251 | 4.72% | 4.16% | 4.08% |

The first-50 rows reproduce the July sample (v3 then: en 5.3, es 3.4, fr 6.7, pt 4.6, on FluidAudio 0.13).
They are too small to decide anything, but they point the same way as the whole split.

**Per file, whole FLEURS split, against v3-int8:** int8v2 is better on 356, worse on 283 and unchanged
on 2,511. Ultra is better on 580, worse on 271 and unchanged on 2,299.

**Errors by kind, whole FLEURS split (S / D / I):**
- **Spanish:** v3 815 / 203 / 82, int8v2 751 / 148 / 88, Ultra 558 / 104 / 77.
- **Portuguese:** v3 744 / 171 / 165, Ultra 647 / 108 / 149.
- **English and French:** Ultra cuts substitutions most (en 613 → 574, fr 886 → 760). int8v2 adds French
  insertions (81 → 99).

### With fillers removed

The removed fillers are um, uh, mm, hmm, mm-hmm, uh-huh, um-hmm, mm-mm and uh-uh, taken out of the
reference and the hypothesis.

| Set | v3-int8 | v3-int8v2 | ultra |
|---|---:|---:|---:|
| AMI ES2004a | **15.66%** | 15.82% | 16.57% |
| AMI ES2010c | 16.66% | 15.91% | **15.05%** |

FLEURS is unchanged by this (it has almost no fillers).

### Where WER moves on the meetings, and why

- **int8v2 on ES2004a** (+0.19 points, 46 diff spans): a wash. It drops one v3 hallucination
  (*"certification or symbols you could think of"*, not in the reference) and adds a few short errors.
  On ES2010c it is better (deletions 627 → 592).
- **Ultra on ES2004a** (+1.6 points, 97 spans). Most of the loss is not misrecognition but **written-form
  output in place of verbatim speech**:
  - **Numbers as digits:** `seven eight one point four` → `17 4`, `twenty five` → `25`. The app's ITN
    turns v3's words into digits anyway, so in the app this part is not a real difference.
  - **Contractions expanded:** `gonna` → `going to` (in the ES2004a hypothesis, 10 → 8 against 7 → 9) and
    `'cause` → `because` (ES2010c: `'cause` 10 → 2, `because` 17 → 28; the reference has 15 and 18).
  - **Fillers and backchannels dropped:** fillers in the hypothesis go 55 → 32 (ES2004a) and 69 → 39
    (ES2010c), against 131 and 132 in the references. Every `mm-hmm` is gone (v3 kept 3), and so are
    several `oh yeah`, `okay` and `yep yep yep okay`.
  - **Real wins too:** it removes v3 hallucinations (*"I'm going to say with less than a little bit"* →
    *"My granddad"*, which matches the audio). On the 30-minute ES2010c it is the best of the three, with
    deletions 627 → 550.
- **For a courtroom-grade record, the style shift matters.** Ultra makes transcripts read more like
  edited prose and less like what was said. The meaning is the same, but backchannels (`mm-hmm`, `okay`)
  are speech acts that a verbatim record keeps.

## Speed, load time, memory: under load, re-measure idle

| Set | Config | RTFx | Load s | Peak footprint MB |
|---|---|---:|---:|---:|
| FLEURS whole split (10.1 h) | v3-int8 | 133× | 0.19 | 67 |
| | v3-int8v2 | 119× | 0.23 | 69 |
| | ultra | 102× | 0.27 | 78 |
| FLEURS first 50 (37.5 min) | v3-int8 / v3-int8v2 / ultra | 138× / 104× / 103× | 0.19 / 0.16 / 0.35 | 57 / 58 / 56 |
| ES2004a (17.5 min) | v3-int8 / v3-int8v2 / ultra | 125× / 136× / 132× | 0.14 / 0.15 / 0.15 | 79 / 75 / 83 |
| ES2010c (30.6 min) | v3-int8 / v3-int8v2 / ultra | 125× / 211× / 118× | 0.16 / 0.22 / 0.16 | 84 / 77 / 83 |

- **RTFx: inconclusive.** Ultra was 23–25% slower on both FLEURS runs, but on par on the meetings. The
  211× for int8v2 on ES2010c is load noise. FluidAudio reports Ultra at parity (~127× vs ~129×). Run
  `bash tools/engine-benchmark/run-asr-model-bench.sh --timing-only --repeat 3` on an idle Mac (no builds,
  Parley not transcribing) before applying the RTFx criterion, and again on the M1 Air target.
- **Load time** is warm, from the compiled Core ML cache: all configurations are under 0.4 s. The first
  load after a download (Neural Engine compile) was not isolated.
- **Peak footprint** is the process only, 56–84 MB for every configuration. The Neural Engine holds the
  encoder weights outside the process, so this does not show a model's memory cost. Use the encoder size
  as the proxy: 433 MB (v3) vs 577 MB (Encoder_v2) vs 578 MB (Ultra), about +145 MB each. That still
  needs a system-level measurement on the M1 Air 16 GB.

## Ship criteria (#338): "WER not worse on any language and RTFx within 10%"

| Criterion | v3-int8v2 | ultra |
|---|---|---|
| WER, FLEURS (4 languages, whole split) | **fails on French** (+0.10 points, ~17 words; better on en/es/pt) | **passes**, better on all 4 (−0.6 to −1.6 points, 9–33% relative) |
| WER, AMI meetings | ES2004a +0.19 (fail, within noise), ES2010c −0.74 | ES2004a **+1.62 (fail)**, mostly written-form style and dropped backchannels; ES2010c −1.09 |
| RTFx within 10% | not established (under load) | not established: −24% on FLEURS, parity on the meetings, under load |

## Recommendations

- **#338 (Ultra): promising, but not switching yet.** It is clearly more accurate on read speech in all
  four languages, and better on the 30-minute meeting. It fails the "not worse on any" rule on ES2004a,
  and its RTFx is unproven. Two things are left to decide:
  1. **RTFx on an idle machine and on the M1 Air:** run `--timing-only`.
  2. **The owner's call on verbatim style:** expanded contractions, dropped `mm-hmm` / `okay`. To size it,
     run ITN-normalised, number-insensitive WER and 3–5 more AMI meetings. This is a fidelity question for
     the record, not only a WER question.

  If both come out acceptable, Ultra is the better default.
- **#350 (Encoder_v2): don't ship as a separate migration.** The gain is small (−0.16 to −0.49 points on
  en/es/pt, −0.74 on ES2010c), French is slightly worse, and it costs the same download and memory as Ultra
  (+577 MB), for less accuracy. If Ultra ships, #350 is moot: Ultra's encoder is already int8-linear, which
  avoids the LUT token flips of FluidAudio#760. Close #350 in favour of #338, or keep it only as the
  fallback if Ultra is rejected on verbatim grounds (int8v2 keeps v3's verbatim style).

## What a switch would need (not implemented)

**For Ultra**, every place below must name the same `.ultra` version:
- **`FluidAudioEngine.isModelCached()`:** `AsrModels.modelsExist(at: defaultCacheDirectory(for: .ultra), version: .ultra)`.
- **`preDownloadModel` and `redownloadModel`:** `AsrModels.download(version: .ultra)`, with `isComplete` and the staging folder on the Ultra cache dir.
- **`ensureLoaded`:** `AsrModels.loadFromCache(version: .ultra)`.
- **`loadedModelEntries`:** the manifest's loaded-file set, from `getRequiredModels(version: .ultra)` plus the vocabulary.
- **`parakeetRepoSlug`:** becomes `FluidInference/parakeet-ultra-coreml`, so `ModelManifestService` record, verify and update check follow, as do the `SettingsView` / `TranscriberApp` call sites that pass the slug.
- **README:** the models table (license line: Ultra is CC-BY-4.0, moondream) and the ~500 MB model-size line.
- **Migration:** `isModelCached()` is false on existing installs until Ultra is downloaded, so they go through Setup / Settings Save (the airgap rule holds). The old v3 folder is not deleted automatically, so decide whether Save removes it.
- **Tests:** the existing `FluidAudioEngine` and manifest tests, re-pointed at the new version.

**For int8V2**, the same list with `encoderPrecision: .int8V2` on `modelsExist`, `download`, `load`
(`loadFromCache` has no precision parameter: use `load(from: defaultCacheDirectory(), …)`) and
`requiredModelsV3(precision: .int8V2)`. The repo slug is unchanged.

**Cost to users:**
- **Ultra:** a 613 MB download into a new folder; the old 470 MB v3 folder stays unless it is removed.
- **int8V2:** a 577 MB `Encoder_v2.mlmodelc` added beside the 433 MB `Encoder.mlmodelc`.
- **Both:** an encoder about 145 MB larger in memory (an estimate, still to be measured on the M1 Air).

## Reproduce

```bash
# Full pass: fetch data (FLEURS via the existing `transcribe` conda env, AMI via curl), download models, run, analyse
bash tools/engine-benchmark/run-asr-model-bench.sh
# Whole FLEURS test split, accuracy only
bash tools/engine-benchmark/run-asr-model-bench.sh --fleurs-full
# Timing only, on an idle Mac
bash tools/engine-benchmark/run-asr-model-bench.sh --timing-only --repeat 3
```

Results land in `~/Library/Application Support/Parley/benchmark/asr-350-338/` (`run-*`, `fleurs-full-*`,
`timing-*`). Each holds `summary.md` with the per-file word diffs. This report used `run-20261124-105022`
and `fleurs-full-20261124-105646`.
