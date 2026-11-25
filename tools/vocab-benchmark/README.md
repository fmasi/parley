# vocab-benchmark

Measures FluidAudio's CTC vocabulary boosting for Parley's custom vocabulary (#340): how many
spoken names and terms it gets right, and how many ordinary words it replaces by a term nobody
said. Results: [docs/benchmarks/2026-11-24-custom-vocabulary.md](../../docs/benchmarks/2026-11-24-custom-vocabulary.md).

The audio is synthetic (`say`, five English voices). The vocabulary and the sentences are invented
(`Sources/VocabBenchmark/Corpus.swift`): no real recording, name or transcript.

```bash
cd tools/vocab-benchmark
swift build -c release
BIN="$(swift build -c release --show-bin-path)/VocabBenchmark"
"$BIN" generate /tmp/vocab-bench      # ~6 min: 1,130 utterances, 16 kHz mono WAV
"$BIN" run /tmp/vocab-bench           # transcribe, rescore across the sweep, print the tables
"$BIN" textonly /tmp/vocab-bench results-0.17.7-ctc110m.json   # the control: no CTC model
```

`run` needs the network once: it downloads the Parakeet CTC 110M model (98 MB) into the work
directory, not into FluidAudio's shared cache, so Parley on the same Mac still sees the model as
not downloaded. It reads Parakeet TDT v3 from FluidAudio's cache (downloading it if absent).

Another FluidAudio release: copy the package elsewhere and build it with
`FLUIDAUDIO_VERSION=0.18.3 swift build -c release` (the version is read in `Package.swift`;
a copy keeps this folder's `Package.resolved` at the version Parley ships).

`run` sweeps `minSimilarity` and the context-biasing weight twice: FluidAudio's proposals as they
are (`Parley rule` off), and with the rule in `VocabularyGate.swift` on top (on): a replacement is
applied only where every replaced word is a spelling the recogniser invented, and terms under five
letters are left out. `textonly` applies that rule to the saved transcripts with no second model
(`TextOnlyRule.swift`), to show what the CTC model itself contributes.

What a run scores, per setting:

- **recall**: the utterances whose term is in the transcript as listed (case and punctuation aside).
- **right**: replacements that put the spoken term where it was spoken.
- **wrong**: replacements that wrote a term where it was not spoken, counted apart on sentences
  that contain a term, on plain filler and on sentences built to sound like a term.
- **capital only**: an ordinary word that only gained a term's capital letter ("will" to "Will").
