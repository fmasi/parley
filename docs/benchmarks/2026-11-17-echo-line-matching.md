# Echo line matching (#363, #365): replay benchmark, 2026-11-17

Numbers only. No recording, transcript, name or line of text from the corpus is kept here or anywhere in the
repository; the harness and its output stayed outside it.

## Why not the 2026-04-06 benchmark

`2026-04-06-echo-dedup.md` cannot be re-run: the `--legacy-dedup` flag it used was removed (8621203), the
storage limit has since removed its seven recordings' audio, and their transcripts were written while echo
lines were deleted rather than flagged, so the lines it judged are no longer in them.

## Method

- Corpus: the owner's finished dual-stream transcripts with lines on both sides, 110 files (2025-09 to
  2026-11, local only), about 21,100 unflagged local lines. 23 of them were recorded with mic echo
  cancellation on.
- Replay: `EchoDeduplicator.deduplicate` once over each whole transcript (as re-detect runs it, not per
  chunk), existing `echo` flags cleared, `filtered` / `duplicate` kept, default thresholds, no embeddings.
  Run at main 04c0583 ("before") and at this branch ("after").
- Coupling: for the 23 cancelled recordings the far-end lift was measured from the archive's two channels
  with `EchoReduction.farEndLift`, per 30-minute window (the pipeline's chunk), and passed as
  `AcousticCoupling` spans. Measured lifts: -2.2 to 6.7 dB on 26 windows (headphones), 20.0 to 31.8 dB on
  20 windows (loudspeakers); nothing between 6.7 and 20 dB.
- Ground truth: there is none to compute against, so every line whose flag changed was read by hand
  next to the remote lines around it, with its speaker label, timing and the chunk's lift, and judged
  echo or the user's own. Lines whose flag did not change were not re-judged.

## Results

| | before | after |
|---|---|---|
| Local lines flagged `echo` | 912 | 893 |
| Newly flagged | | 8 |
| No longer flagged | | 27 |

The 35 lines that changed:

| Change | Lines | Judged | Effect |
|---|---|---|---|
| Newly flagged, numbers written two ways (#363) | 7 | echo | 7 false negatives removed |
| Newly flagged, short user line inside a 74 s remote line | 1 | probably the user's own | 1 false positive added (uncertain) |
| No longer flagged, headphone chunks (a), lift ≤ 6.7 dB | 13 | the user's own (no acoustic path) | 13 false positives removed, the 2 lines of #365 among them |
| No longer flagged, timing or length (b) | 6 | the user's own (5), probably the user's own (1) | 6 false positives removed (one line counted twice: two transcript files of the same call) |
| No longer flagged, timing or length (b) | 8 | echo | 8 false negatives added |

The 8 false negatives added are all in one loudspeaker recording made without echo cancellation, whose
mic recogniser cut lines differently from the system one: the echo line carried words of a remote line
that ended more than 0.3 s before it, or added a word ("like", a repeated phrase). The same recording keeps
62 lines flagged. A missed echo line is visible in the transcript; a wrong flag hides the user's words.

## Variants rejected on this replay

- **(b) judged against the best-matching remote line only**: 32 echo lines lost in that same recording.
  Replaced by judging a line against every remote segment within 0.3 s of it.
- **English contractions expanded** ("she's" → "she is"): short lines of the user's became "contained"
  in long remote lines through the added common words (new false positives).
- **Contractions and their long forms joined into one token** (`she_is`): 4 echo lines dropped under the
  0.7 threshold, and a short user line was newly flagged. Contractions are split at the apostrophe as before.
- **"%" read as "percent"**: raised the containment of a short user line in a long remote line. Dropped.

## Limits

- Whole-transcript replay, not the per-chunk pipeline: cluster verdicts differ from the recorded ones
  (the pipeline flagged 422 lines on the same files, against 912 here).
- Judged by reading, not by listening; "probably" marks the lines a reading could not settle.
- English numbers only; the other languages in the corpus (French, Portuguese) are covered by the
  per-line safeguards, not by normalisation.
