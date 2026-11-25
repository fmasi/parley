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

After the review fixes (scores never below the plain reading, the 3-word rule on the fewer count, rule (b)
on the speech a line overlaps plus the edge words it shares with its neighbours):

| | before | after |
|---|---|---|
| Local lines flagged `echo` | 912 | 894 |
| Newly flagged | | 8 |
| No longer flagged | | 26 |

The 34 lines that changed:

| Change | Lines | Judged | Effect |
|---|---|---|---|
| Newly flagged, numbers written two ways (#363) | 7 | echo | 7 false negatives removed |
| Newly flagged, short user line inside a 74 s remote line | 1 | probably the user's own | 1 false positive added (uncertain) |
| No longer flagged, headphone chunks (a), lift ≤ 6.7 dB | 13 | the user's own (no acoustic path) | 13 false positives removed, the 2 lines of #365 among them |
| No longer flagged, timing, length or the 3-word rule | 5 | the user's own | 5 false positives removed (one line counted twice: two transcript files of the same call) |
| No longer flagged, timing or length (b) | 8 | echo | 8 false negatives added |

The 8 false negatives added are all in one loudspeaker recording made without echo cancellation. The review
widened what a line may carry (remote lines that ended up to 0.8 s before it, flagged remote speech
included); it did not bring any of them back, because none is within that reach:

- 5 start with words of a remote line that ended 1.3 s or more before them, or whose source the remote side
  never transcribed nearby: the two recognisers placed the same speech seconds apart, more than any echo
  delay.
- 2 hold a word or phrase the mic's recogniser added, and so are longer than the remote speech.
- 1 starts 0.34 s before its source, 0.04 s outside the 0.3 s tolerance.

The same recording keeps 62 lines flagged. A missed echo line is visible in the transcript; a wrong flag
hides the user's words.

## Measuring the lift without echo cancellation

Rule (a) needs `far_end_lift_db`, which only echo cancellation records today (off by default). The lift
needs no canceller: `EchoReduction.farEndLift` reads levels only. Measured on a synthetic 30-minute chunk
pair (48 kHz Int16 WAVs, read at 16 kHz a block at a time, RMS per 100 ms frame), a debug build took
1.8 s for both files; the memory is two arrays of 18,000 frame levels plus one 4-second block per file.
On the replay, the lift computed from the archives alone matched the canceller's own record where the
issues quote it: 2.5 dB on the headphone call of #365, 31 dB on that day's loudspeaker call. Not
implemented here; a follow-up.

## Variants rejected on this replay

- **(b) judged against the best-matching remote line only**: 32 echo lines lost in that same recording.
  Replaced by the speech the line overlaps plus the edge words it shares with its neighbours.
- **(b) judged against every remote segment within 0.3 s of the line** (the first fix): a far end that
  spoke again right after a repetition made the repetition "short enough" to be a copy (found in review).
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
- 15 dB sits in a gap nobody measured: no window fell between 6.7 and 20 dB. A quiet loudspeaker in a
  noisy room could measure there (7-15 dB), and its single echo lines would then not be flagged.
- Rule (b) holds back a copy of a whole line that starts more than 0.8 s after its source. On an output
  slower than that (AirPlay, about 2 s) such echo copies are held back too; only an echo cluster flags them.
