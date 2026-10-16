# FluidAudio evaluation against Parley's needs (2026-10-16)

**Scope.** FluidAudio 0.15.5 → 0.17.7 (the bump is PR #337), the whole library, and the models it
now ships, read against what Parley uses. Parley adopted FluidAudio early (Parakeet v3, the offline
pyannote + WeSpeaker + VBx diarizer, Silero VAD, ITN) and never surveyed the rest. This is a
document review plus a read of Parley's code. **No benchmark was run**: every accuracy number below
is FluidAudio's own (M5 Pro, their corpora), not Parley's. Each opportunity names the benchmark that
would prove it.

**Sources.** FluidAudio README, `Documentation/` (ASR, Diarization, Enhancement, Models,
Benchmarks), release notes v0.15.5..v0.17.7, the Hugging Face model cards (licences checked
2026-10-16). Parley: `docs/pipeline.md`, `docs/parameters.md`, `TranscriberCore/FluidAudioEngine.swift`,
`FluidAudioDiarizer.swift`, `VadSpeechMap.swift`, `docs/benchmarks/`, `tools/engine-benchmark/`.

**Yardstick** (AGENTS.md, memory): airgapped courtroom-grade record; chunked OFFLINE processing
(streaming rejected for quality); dual-stream mic + system; target MacBook Air M1 16 GB, zero idle
wakeups; macOS 15+; a silent wrong answer is the worst failure.

## 1. Top recommendations

| # | Recommendation | Benefit | Effort | Risk | Proof needed |
|---|---|---|---|---|---|
| 1 | Benchmark **Parakeet Ultra** as the default ASR (drop-in for v3) | FLEURS 24-language mean WER 14.81 → 11.67 %, English test-other 4.12 → 3.81 %, same speed | S (benchmark) + S (switch + migration) | Low: same architecture, tokenizer, API; +150 MB encoder | **Benchmark** (FLEURS via our harness, AMI chunked path) |
| 2 | Benchmark **FluidAudio-native CJK / auto-language engines** (SenseVoice, Parakeet-ja, Cohere, Paraformer-zh) against SpeechAnalyzer | Could close #147 and #223 inside the dependency we already ship: offline, deterministic, no Apple locale install | M | Medium: sizes (Cohere 1.8 GB), SenseVoice licence is custom | **Benchmark** (FLEURS ja/ko/zh) |
| 3 | **Custom vocabulary** for names and jargon, seeded from the calendar event | Names and company terms are what a reader of a transcript notices; FluidAudio reports 99.4 % dictionary recall | M | Medium: a wrong substitution is a silent wrong answer, so it must be opt-in and recorded | **Benchmark** (synthetic `say` audio + AMI) and a **device test** |
| 4 | Cache segmentation + embeddings in **re-detect** (`prepare()` / `cluster()`) and show **progress** | Re-detect at a new count becomes cheap; closes the "spinner only" complaint (#203) | S | Low | Unit tests, a timing on one long file |
| 5 | **LocalVQE AEC** as a derived mic signal, using the system track as the reference | Removes speakerphone bleed at the root; today's EchoDeduplicator only flags it afterwards | L | High: double-talk can clip the user's own words; beta upstream | **Device test** on speakerphone calls (#183 class) + A/B benchmark |

Not recommended now: every streaming model (§3.4), Sortformer / LS-EEND, Redux, Phonon-2, Nemotron 3
Diarization (gated, GPU-only offline profile), TTS (§3.9).

Filed from this review: see §7.

## 2. What Parley uses today

| Area | In use | Where |
|---|---|---|
| ASR | Parakeet TDT 0.6B **v3** via `AsrModels.loadFromCache()` (the library default), offline, one file per call, fresh `TdtDecoderState` per file, `language: nil` | `FluidAudioEngine.swift` |
| Text | NeMo ITN through `TextNormalizer` (NemoTextProcessing), word timings kept | `FluidAudioEngine.swift` |
| Diarization | `OfflineDiarizerManager`: pyannote segmentation + WeSpeaker + VBx; `embeddingExcludeOverlap: true`; optional threshold / max speakers / forced count | `FluidAudioDiarizer.swift` |
| VAD | Silero via `VadManager`, as a quality signal in `SpeakerAssignment` | `VadSpeechMap.swift` |
| Second engine | Apple SpeechAnalyzer (CJK only; blank on the chunked path, #223; needs a locale, #147) | benchmark 2026-07-16 |
| Echo | `EchoDeduplicator`: time overlap + word overlap + embedding cosine (evidence only), judged per cluster | `docs/pipeline.md` |
| Model provenance | `ModelManifestService` records the HF commit and SHA-256 per file | `ModelManifest*.swift` |

Re: "FluidAudio 0.14 dropped per-source decoder state". Parley transcribes each WAV as its own
offline call with a fresh state, and mic and system are separate files, so there is no state to
route between sources or chunks. The change is benign by construction. What it does not tell us is
how a word cut by the 30-minute chunk boundary is handled; that is a Parley property, not a
FluidAudio one, and has no measurement yet.

## 3. Capability inventory and fit

### 3.1 ASR models (batch)

| Model (`AsrModelVersion`) | Languages | Size | FluidAudio-reported accuracy / speed | Fit |
|---|---|---|---|---|
| **v3** (default, in use) | 25 European | enc 445 MB (6-bit LUT) | LS clean/other 2.27 / 4.12 %, FLEURS mean 14.81 %, ~129× RTFx | Baseline |
| **Ultra** (0.17.3) | same 25, same tokenizer and API | enc 595 MB (int8) | 2.13 / 3.81 %, FLEURS 11.67 % (better in 24 of 24), ~127× | **Candidate default** (rec. 1) |
| Redux (0.17.3) | same 25 | enc 183 MB (2-bit), macOS 15+ | 2.71 / 5.12 %, FLEURS 13.06 %, ~84× | Worse English, slower, first ANE compile "several minutes". Skip |
| Phonon-2 (0.17.5) | English only | ~360 MB, macOS 15+ | 2.47 / 4.62 %, 159× | Smaller and faster but less accurate than v3 on English. Skip unless an 8 GB tier appears |
| v2 | English | – | – | Superseded by Ultra |
| TDT-CTC-110M | English | 110M | LS clean 3.01 %, built-in CTC head for vocabulary | Candidate only if we want the cheapest vocabulary path; weaker WER |
| Parakeet Unified 0.6B (batch) | English, with punctuation | – | 2.15 % LS clean, 123× | English-only. Worth one line in the Ultra benchmark, not a plan |
| Parakeet TDT Japanese | ja | – | 6.85 % CER JSUT, 10.8× on M2 | CJK candidate (rec. 2) |
| SenseVoiceSmall (FunASR) | 50+, **auto language detection** | – | not stated | CJK + routing candidate (rec. 2); licence "other" (check) |
| Paraformer-large | zh | INT8 variants | – | CJK candidate, Mandarin only |
| Cohere Transcribe (beta) | 14 incl. ja/zh/ko, language passed explicitly | enc 1.8 GB, 35 s per call | – | Heavy for an M1 Air; a 35 s window means more stitching. Low priority |
| Streaming: EOU, Nemotron (EN + multilingual, `prompt_id` language hint, ~40 languages, local-path only), Unified streaming | – | – | – | Rejected by the no-streaming decision (§3.4) |

Notes on the existing path that the bump changes (flagged for the device test in #337; the seam fixes #708 and #759 are already in 0.15.5):
- 0.15.7 makes the v3 long-form path default to **no-mel, silence-aligned window starts** (#869);
  0.15.6 adds a **seam-gap repair pass** for content dropped at chunk merges (#761). Parley feeds up-to-30-minute files, so these are exactly the
  paths it exercises. Compare word counts on a long chunk before and after.
- 0.15.8: blank-decode recovery ladder (#910), punctuation ids from the loaded vocabulary (#906).
- int8-linear encoder option for v3 (#872, issue #760: the 6-bit LUT "flips tokens on some
  windows"). Ultra ships int8 and reports WER-identical to fp16.

### 3.2 Language hint and detection

- `language:` on the transcribe call enables `TokenLanguageFilter` (18 languages, Latin and Cyrillic):
  it stops wrong-script tokens (their example: Cyrillic leaking into Polish). **Parley passes
  `nil`.** There is no way to supply a language today; Config has no language key.
- v3 has no language ID output. Only Nemotron multilingual (streaming, local path only) and
  SenseVoice give a language tag.
- This is the missing source for #147. A hint cannot be the user's per-recording setting (the
  maintainer's constraint: forgotten settings fail silently). SenseVoice's tag, or a separate
  language-ID model, are the automatic candidates. A dual-stream call can be two languages at once
  (observed pt-BR vs pt-PT), so the language decision is per channel.

### 3.3 Custom vocabulary (CTC keyword spotting)

- Works on v3 through a **separate CTC encoder** (Parakeet CTC 0.6B, ~64 MB extra memory,
  ~26× real-time for the whole pipeline in their table; CTC head variants only exist for the 110M model).
  Rescoring runs on the transcript plus token timings, so it fits the offline chunk path, and
  FluidAudio recommends file-based use for best accuracy.
- Reported 99.4 % dictionary recall. The over-firing knobs (per-term thresholds, taper, disabling
  the acoustic spotter-rescue) exist because short or colliding terms replace ordinary words; their
  own table shows the safe settings cost recall. 0.15.7 adds decode-time biasing for Nemotron
  (streaming only, so not usable here).
- Fit: strong for the product (names, company and product terms). Guardrail needed: a substitution
  is an edit to the record. Keep the raw token text in the segment's words, mark substituted words,
  and list the vocabulary used in `metadata`. Seed from the calendar event (title and attendee
  names, `CalendarService` already reads the event) plus a user glossary. Airgap: the CTC models
  download at Setup or Save only.

### 3.4 Streaming and real-time (rejected, confirmed)

EOU, Nemotron streaming (EN, multilingual), Unified streaming, Sortformer, LS-EEND, Nemotron 3
streaming profiles, and the streaming pyannote pipeline are real-time tools. FluidAudio's own
benchmark notes say the streaming diarizer gives "substantially worse DER than the offline pipeline"
and is "fragile to clustering". That agrees with the 2026 decision (chunked offline, measured
62× combined). No change. Revisit only for a live-captions feature.

### 3.5 Diarization

| Component | Status | Fit |
|---|---|---|
| Offline pyannote community-1 + WeSpeaker + VBx (in use) | new since 0.15.5: 0.16 fixed the inverted AHC threshold (`sqrt(2-2t)`) and added constrained assignment; 0.15.7 holds speaker caps against both cluster censuses (#891) and propagates cancellation (#886); 0.15.8 **pins the artifacts to an immutable model revision** (#939). Already in 0.15.5: deterministic VBx via K-Means `n_init` (#735), `computeUnits` honoured (#743), zero-vote spans re-embedded (#751) | Keep. Determinism and pinned revisions help the provenance story. #337 covers the threshold change |
| `OfflineDiarizerManager.prepare()` / `cluster()` split (#789, 0.15.6) | Segmentation + embeddings cacheable, clustering rerun | **Re-detect** (#67): changing the stated count should only rerun clustering (rec. 4) |
| `progressHandler` on `performCompleteDiarization` (#753, already in 0.15.5; `progressCallback` in the docs) | Chunks processed / total | **#203** (re-detect shows only a spinner) and a long-call progress bar |
| Nemotron 3 Diarization (0.17.0, 0.17.4) | up to 8 speakers, arrival-ordered, `offline` preset "highest accuracy" but **GPU-only** (ANE compiler limit), model weights **gated until NVIDIA's public release** at the time of the doc, licence OpenMDW-1.1 | Interesting only as an accuracy challenger on AMI; GPU use is a battery cost on an M1 Air. Benchmark later, not now |
| Sortformer (4 speakers), LS-EEND (10) | streaming | Rejected (§3.4) |

### 3.6 Speaker embeddings and identification

`SpeakerManager` (enroll, `findSpeaker` by cosine distance, merge, permanence flags,
`SpeakerUtilities`), per-segment embeddings from the offline diarizer, and a beta **CAM++**
embedding backend (0.15.6). Parley already stores embeddings per chunk and matches them in
`SpeakerReconciler` (greedy cosine, EMA). Cross-session recognition (#26, #68) needs a stored
profile per named person and a suggest-then-confirm UI; the matching code exists in FluidAudio and
in Parley. No new library capability is required; it is a Parley feature with a privacy design
question (embeddings are biometric; BIPA tailwinds noted in the positioning memory). No new issue;
this review adds the facts to #26.

### 3.7 VAD

Silero v6.2.1 artifact (#734, already in 0.15.5); FSMN-VAD backend beta (0.15.6); `VadManager` segmentation
docs. Parley uses Silero as a quality signal. Nothing here changes a result.

### 3.8 Enhancement: LocalVQE (AEC + noise suppression + dereverberation)

Beta in 0.17.5. 4.8M parameters (v1.3) or 1.3M (v1.2), 16 kHz mono, CPU (fp32), 16 ms algorithmic
latency, Apache-2.0. Inputs: the mic and a **far-end reference of equal length**.

- Fit with Parley: the system track *is* the exact far-end reference, already recorded as a separate
  file. This is the classic AEC setup that issue #39 wanted, available after capture instead of
  through Apple VoiceProcessing IO at capture time (which would change the recorded mic).
- Courtroom constraint (#39): the raw mic WAV and the archive stay untouched. Enhanced audio would
  be a labelled derivative used for ASR and diarization input only.
- It does not replace `EchoDeduplicator`. Residual echo, route changes and a reference that is not
  sample-aligned all leave echo behind; the deduplicator remains the safety net and the thing that
  tells the user. AEC lowers how often it has to fire.
- Risk: double-talk. An echo canceller that over-suppresses removes the *local* speaker's words,
  which is the silent-loss failure Parley exists to prevent. FluidAudio states the benchmark is
  only partially reproduced, ERLE protocol ambiguous, and live alignment, route changes and
  sustained load are unvalidated ("not yet exercised inside production call pipelines").
- Needs: clock alignment between the tap and the mic (Parley already measures per-track timing and
  rate drift), and a decision whether to run ASR on both raw and enhanced mic and compare.

### 3.9 Other

- **ITN / text normalization**: NeMo `text-processing-rs` is already used. 0.15.7 makes it an
  opt-out trait (ASR-only consumers can drop it); Parley uses it, so keep it. ITN supports EN, DE,
  ES, FR, HI, JA, ZH; Parley's per-segment ITN keeps working.
- **Download and cache**: `ModelHub` with resumable downloads, byte progress, artifact validation,
  retry honouring `Retry-After`, a **stall watchdog** and a cache that survives transient network
  errors (0.15.5, 0.15.6). `ModelRegistry.repoOverrides` lets a mirrored repo be used. Parley's
  rule (models download only at Setup or Settings Save) is unaffected; `ModelManifestService`
  should record the new Ultra repo if adopted.
- **Logging**: FluidAudio's `AppLogger` mirrors to the console by default and 0.17.4 added
  `AppLogger.minimumLevel` and `mirrorsToConsole` "to keep debug output, including recognised
  words, off the console". Parley never sets them. Under AGENTS.md's log-privacy rule (transcript
  text `.private`), this is worth one check (issue below).
- **TTS** (Kokoro, PocketTTS, Supertonic, Chatterbox, LuxTTS, Paradee, NeuTTS, StyleTTS2): not
  relevant; Parley does not synthesise speech. Only the dependency fact matters: TTS downloaders are
  compiled in, but not linked into Parley's targets (PR #337 checked the diff for new network use).

## 4. Fit against the principles

| Principle | Result |
|---|---|
| Airgap | All candidates are on-device Core ML. Everything downloads at Setup or Save only, as today. New downloads add Ultra (+150 MB), the CTC encoder (~64 MB), LocalVQE (a few MB), or the CJK models |
| Courtroom accuracy | Ultra is a pure accuracy gain by FluidAudio's numbers. Vocabulary and AEC both edit the evidence and need provenance (what was substituted, what was cleaned). Raw audio stays canonical |
| Chunked offline | Everything recommended is file-based. Nothing needs streaming |
| Dual stream | LocalVQE is the only item that uses the dual-stream structure (system track as reference). Language is decided per channel |
| M1 Air 16 GB, zero idle wakeups | Ultra's int8 encoder is ~150 MB larger on disk; RTFx is at parity. The CTC pass adds ~130 MB memory and time. `FluidAudioEngine` already unloads on a timer, nothing here adds an idle wakeup. Redux's multi-minute first ANE compile would hurt a first launch |
| macOS 26+ | Ultra needs macOS 14+, Redux and Phonon-2 macOS 15+. Fine |
| Licences | Ultra, Redux, Phonon-2, v3, Parakeet-ja: CC-BY-4.0, consistent with the README's "all weights CC-BY-4.0 or MIT". Cohere Transcribe and LocalVQE: Apache-2.0. **SenseVoice: custom licence ("other")**, and **Nemotron 3 Diarization: OpenMDW-1.1**: both need a read before shipping. The README models table must gain any adopted model |

## 5. Benchmarks that would prove each item

All use `tools/engine-benchmark/` (it already runs FLEURS per language and the AMI fixtures) and run
on the M5 Pro first, then once on an M1 Air-class Mac for time and memory.

1. **Ultra vs v3**: FLEURS 50 utterances × the European languages in our 2026-07-16 report, plus the
   AMI ES2004a chunked path (WER per stream), plus a 30-minute file. Record WER, RTFx, peak RSS,
   load time. Ship when WER is not worse on any language and RTFx within 10 %.
2. **CJK in FluidAudio**: FLEURS ja/ko/zh (CER) for Parakeet-ja, SenseVoice, Cohere, Paraformer-zh
   vs SpeechAnalyzer's 7.2 / 4.0 / 7.8 %; plus SenseVoice's language tag accuracy on a mixed
   FLEURS set (the routing question). Install models once, serially (the harness bug noted in the
   2026-07 report).
3. **Vocabulary**: synthetic `say` audio with 50 names and product terms spoken inside AMI-like
   filler; measure term recall and **false substitutions on ordinary words** (the number that
   matters). Then one real recording.
4. **Re-detect cache**: wall time of a re-detect at a new count with and without the cached
   segmentation; a golden test that the clusters equal a fresh run.
5. **LocalVQE**: speakerphone recordings with known local text. Measure echo-flagged segments,
   **local word loss** in double-talk (words in the raw-mic transcript missing after AEC), mic-channel
   WER, and the tap/mic alignment error. Device test on real calls before any default.

## 6. Open questions

- Ultra is a derivative (moondream) of v3; FluidAudio shows its numbers but we have not seen its
  failure modes on meetings. The benchmark above answers that.
- Do we want one multilingual engine or an engine per language group? SenseVoice's tag could make
  one router for everything, but its accuracy on European languages is unknown against Ultra.
- Whether `language:` should be exposed in Settings as an *optional hint* once routing exists.
- The SpeechAnalyzer engine stays until the CJK benchmark says otherwise.

## 7. Filed issues

All in milestone v0.10.

| Issue | Item |
|---|---|
| [#338](https://github.com/fmasi/parley/issues/338) | Benchmark Parakeet Ultra as the default model |
| [#339](https://github.com/fmasi/parley/issues/339) | FluidAudio-native CJK / auto-language engines vs SpeechAnalyzer |
| [#340](https://github.com/fmasi/parley/issues/340) | Custom vocabulary, seeded from the calendar event |
| [#341](https://github.com/fmasi/parley/issues/341) | Re-detect: cached segmentation + embeddings, progress |
| [#342](https://github.com/fmasi/parley/issues/342) | LocalVQE AEC benchmark vs EchoDeduplicator |
| [#343](https://github.com/fmasi/parley/issues/343) | Keep FluidAudio's recognised words off the console |

Findings added by comment to #26, #39, #147 and #223.
