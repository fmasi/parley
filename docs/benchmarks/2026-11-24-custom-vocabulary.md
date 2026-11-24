# Custom vocabulary: FluidAudio CTC boosting (2026-11-24, #340)

**Verdict: do not build #340 as specified.** FluidAudio's CTC vocabulary boosting reaches its
advertised recall only by writing vocabulary terms over ordinary words: 115 wrong substitutions per
hour at its defaults (FluidAudio 0.18.3; 340 per hour on 0.17.7, which Parley ships). The only
setting that brought wrong substitutions to zero is a rule Parley has to add on top, and that rule
does the same job with no CTC model at all. So the 98 MB model, its download and its second pass
over the audio earn nothing.

What is worth a decision instead: a small glossary rule with no model, which fixed 1 in 6 of the
missed terms with no wrong substitution in this run. See "What to do with this".

**Machine:** Apple M5 Pro, macOS 27.2.1, 48 GB.
**Data:** 1,130 synthetic utterances (65.0 min, 10,830 ordinary words), `say` with five English
voices (US, UK, Australian, Irish, Indian). 52 invented terms: 16 distinctive names, 2 full names,
8 names that are also ordinary words ("Grace", "Hunter"), 10 short terms that sound like ordinary
words ("Jira", "Wren"), 12 products, 4 jargon words. 780 utterances speak one term each in AMI-like
meeting filler; 150 are plain filler; 200 are sentences built to sound like a term without
containing one ("the terrace forms a nice space", "we need to sync the calendars"). The whole
vocabulary is loaded for every utterance.
**Models:** Parakeet TDT 0.6B v3 (what Parley runs) plus Parakeet CTC 110M, the encoder FluidAudio
documents for 0.6B models (98 MB on disk; the issue says "CTC 0.6B", which is a different,
larger repo).
**Harness:** `tools/vocab-benchmark`. Each replacement is checked against the reference text by
alignment: "right" writes the spoken term where it was spoken, "wrong" writes a term anywhere else.

## Without the vocabulary

Parakeet v3 writes 407 of the 780 spoken terms as listed (52.2%): distinctive names 55/240, full
names 10/30, ordinary-word names 113/120, short terms 66/150, products 136/180, jargon 27/60.

## FluidAudio's own thresholds

`minSimilarity` is the string similarity a transcript span needs to a term. `cbw` is the bonus a
term's CTC score gets before it is compared with the score of the words the recogniser wrote; 4.5
is FluidAudio's default for 11 to 100 terms, 0 means the term has to win on the audio alone.
FluidAudio 0.18.3:

| minSimilarity | cbw | recall | terms fixed | wrong: in term sentences | in filler | in sound-alikes | wrong per hour |
|---|---|---|---|---|---|---|---|
| 0.50 | 4.5 | 87.6% | 276 | 83 | 30 | 73 | 171.7 |
| **0.55 (default)** | **4.5** | **84.4%** | 251 | 52 | 16 | 57 | **115.4** |
| 0.60 | 4.5 | 82.1% | 233 | 21 | 13 | 57 | 84.0 |
| 0.70 | 4.5 | 72.4% | 158 | 1 | 5 | 28 | 31.4 |
| 0.85 | 4.5 | 58.2% | 47 | 0 | 0 | 9 | 8.3 |
| 0.55 | 0 | 61.7% | 74 | 3 | 1 | 12 | 14.8 |
| 0.70 | 0 | 60.3% | 63 | 0 | 0 | 2 | 1.8 |
| 0.85 | 0 | 55.6% | 27 | 0 | 0 | 0 | 0.0 |

The wrong substitutions at the default are ordinary words turned into names: "market" to "Mark",
"case" to "Chase", "price." to "Grace", "winter." to "Hunter", "crane" to "CRAN", "tires" to "Ines".
Turning the acoustic rescue off changed nothing with 52 terms. No correctly written term was lost
at 0.70 and above.

FluidAudio 0.17.7 is worse and unstable on this Mac: 339.6 wrong per hour at the default in one run,
279.6 in another, and its CTC front end emitted "blank" for 79.7% and 99.6% of frames in two runs
against 58.8% on 0.18.3. That is FluidAudio's bug #1074 (macOS 27 runs part of the mel front end
on the Neural Engine; 0.18 pins it to the CPU). On 0.17.7 the "acoustic evidence" is mostly noise.

## With a Parley rule on top

The rule: a replacement is applied only when every word it replaces is a spelling the recogniser
invented, meaning no word or name of macOS's word list (`/usr/share/dict/words`, its inflections and
a short list of modern words). Terms under five letters are not used. An ordinary word then cannot
be rewritten at all, whatever the thresholds. Same sweep, the rule applied to FluidAudio's
proposals (default `cbw`; 0.17.7 gives the same numbers from 0.55 up):

| minSimilarity | recall | terms fixed | wrong: in term sentences | in filler | in sound-alikes | wrong per hour |
|---|---|---|---|---|---|---|
| 0.50 | 68.6% | 128 | 5 | 0 | 0 | 4.6 |
| 0.60 | 66.4% | 111 | 2 | 0 | 0 | 1.8 |
| 0.65 | 64.2% | 94 | 1 | 0 | 0 | 0.9 |
| **0.70** | **60.5%** | **65** | **0** | **0** | **0** | **0.0** |
| 0.85 | 56.4% | 33 | 0 | 0 | 0 | 0.0 |

The wrong ones below 0.70 are a mangled name rewritten as another listed name ("Priyrahman" to
"Priyanka", "Yunker" to "Hunter"): the wrong person, which is the worst kind. At 0.70 the 65 fixes
are near-miss spellings: "Dimitri" to "Dmitri", "Matias" to "Matthias", "Ziomara" to "Xiomara",
"Okonko" to "Okonkwo", "canban" to "Kanban". By category at 0.70: distinctive names 55 to 108 of
240, products 136 to 142, jargon 27 to 33, everything else unchanged.

## The control: the same rule with no CTC model

The same rule on the plain transcript, the invented spelling replaced by the listed term closest
in letters (edit distance), no second model and no audio:

| minSimilarity | recall | terms fixed | wrong: in term sentences | in filler | in sound-alikes |
|---|---|---|---|---|---|
| 0.60 | 65.6% | 115 | 11 | 0 | 0 |
| 0.65 | 64.7% | 98 | 1 | 0 | 0 |
| **0.70** | **60.9%** | **68** | **0** | **0** | **0** |
| 0.85 | 56.5% | 34 | 0 | 0 | 0 |

At 0.65 and above it matches the CTC path (68 fixed against 65 at 0.70). The CTC model only helps
below that, where it stopped "Priya" (heard right) from becoming "Priyanka" 10 times. That the CTC
path gives identical numbers on 0.17.7, where the CTC output is mostly blank, says the same thing:
at FluidAudio's default weight the audio does not decide, the spelling does.

## Cost of the CTC path

98 MB download. CTC inference plus spotting ran at 158x real time on 0.18.3 (41x on 0.17.7), and
one rescoring pass took 0.05 s per minute of audio with 52 terms (0.13 s on 0.17.7). Its output is
about 3 MB per minute of audio (12.7 frames a second, 1,025 values each), so about 95 MB for a
30-minute chunk unless it is rescored in windows. Memory was not
measured: Core ML's memory does not show in the process's resident size.

## What this does not show

- Real meetings. `say` voices are clean and consistent; real speech will mangle names in more ways
  and will hold ordinary words the word list does not know. One recorded call is still owed before
  any of this ships.
- Other languages. The CTC model and the word list are English. On another language every word
  would look "invented", so the rule would have to stay off there.
- Names heard as real words. "Nguyen" heard as "win" and "Databricks" heard as "data bricks" are
  never fixed by the rule, by design: nothing tells them from the words themselves.
- The 0.6B CTC variant, which was not run.

## What to do with this

1. **Not the CTC feature.** Its safe settings need the rule above, and with the rule the model adds
   nothing. Close or re-scope #340.
2. **A glossary rule with no model is the candidate**, if 1 in 6 is worth having: opt-in, a user
   glossary plus the calendar's attendee names, invented spellings only, similarity 0.70, every
   rewrite recorded with what was heard and the term list in `metadata`. No download, no change to
   the airgap, works with either engine, and can be checked on existing transcripts before it
   touches a new one. This is a different feature from the one the issue describes, so it needs the
   owner's decision.
3. What would move the hard names ("Saoirse" heard as "Sersha", too far apart in letters) is not a threshold
   but the user saying how a name sounds: a "sounds like" spelling per glossary entry. Not measured
   here.

## FluidAudio 0.18 notes

The calls this benchmark uses (`CtcModels.download` / `load`, `CtcKeywordSpotter`,
`VocabularyRescorer.create`, `ctcTokenEvaluateCandidates`) compile unchanged against 0.18.3. 0.18
changes the behaviour, not the API: the mel front end runs on the CPU (#1074), a word the recogniser
was confident of gets no bonus against a term unless it is a close spelling (#967), the acoustic
rescue runs only for vocabularies of 10 terms or fewer, and `VocabularyBoostingSession` takes
`Thresholds` (`cbw`, `minSimilarity`). These roughly halve the wrong substitutions and are still far
from enough.

## Reproduce

```bash
cd tools/vocab-benchmark && swift build -c release
BIN="$(swift build -c release --show-bin-path)/VocabBenchmark"
"$BIN" generate /tmp/vocab-bench && "$BIN" run /tmp/vocab-bench
"$BIN" textonly /tmp/vocab-bench results-0.17.7-ctc110m.json
```
