# Development process

How work gets from an idea to a release. This exists because the alternative — fixing bugs one at a
time, straight to CI, and versioning by feel — let a diarization bug that merged **every speaker into
one** ship for months, invisible to the entire test suite.

## 1. Group related work into one PR

Fix related bugs and features **together**, in a single branch. A PR should be one coherent story a
reviewer can hold in their head.

- **Group:** bugs in the same subsystem, a fix and the test that proves it, a fix and the docs it
  invalidates.
- **Don't group:** unrelated subsystems. If a second, larger defect surfaces mid-branch, **file it and
  leave it** — bundling it makes the branch unreviewable. (Example: the crash-recovery cluster #135 was
  found during #136 and deliberately left out.)

Grouping matters because bugs in one subsystem are usually *entangled*. Fixing them one at a time
means each fix is reviewed without the context of the others — which is how a fix for one bug ends up
reintroducing another.

## 2. Code-council the PR BEFORE it goes to CI

Run a multi-agent adversarial review over the **complete diff** before pushing for CI.

A council is: several reviewers, each with a distinct lens (correctness, boundaries, silent failure,
robustness/tests), whose findings are then attacked by independent skeptics tasked with *refuting*
them. Only findings that survive get reported.

**Why before CI, not after:** CI proves the code compiles and the tests you thought to write pass. It
cannot tell you the tests are asserting nothing, that a merge function ships no bytes, or that the
alarm you just added will cry wolf on every meeting. Those all happened, and a council found all
three.

**Take the council's findings on your own new code seriously.** Both councils run so far found real
bugs *inside the code written to fix the previous bug*:

- A locator that silently shifted the timeline past a missing chunk — and a test that asserted the
  broken behaviour as correct.
- A rate-drift watchdog that false-fired on a healthy recording and then **disarmed itself for the
  rest of the session**.
- A classifier that still routed one input shape to the wrong file — the exact bug it was written to
  fix.

Fix the must-list, then push.

## 3. Then CI, and monitor it

Push, open the PR, watch the checks. Resolve anything pertinent — including the review bot's, using
judgment (it catches real issues but also chases doc staleness).

CI must be able to catch the class of bug you just fixed. If it can't, **that is part of the fix**:
the `diarization-guard` job exists because the regression tests skipped silently in CI, so the suite
reported green while asserting nothing about speaker separation.

**What CI cannot cover:** anything needing real audio hardware — the capture path, Bluetooth/HFP
behaviour, ScreenCaptureKit, the Core Audio tap. These require device validation on a real Mac, and
the measurements belong in the commit message.

## 4. Device-test before merge

Anything touching capture, audio, or the pipeline gets tested on real hardware with a real recording
before merge. State the measurement, not the impression: *"56.7% zero-padding → 5.8%"*, not *"sounds
better"*.

## 5. Decide the version deliberately

Pre-1.0, we use `0.MINOR.PATCH`:

| bump | when |
|---|---|
| **PATCH** (`0.8.1` → `0.8.2`) | Bug fixes only. No new capability, no new config or CLI surface, no change a user must be told about. |
| **MINOR** (`0.8.x` → `0.9.0`) | Any new capability — a feature, a new CLI subcommand, new config keys — **or** a change that materially alters output the user relies on, even if it is "just" a bug fix. |

That last clause is the one that matters. A bug fix that **changes what the transcripts say** is not a
patch in spirit, even if it is one in letter. Speaker labels suddenly becoming correct is a change
users will notice in their records, and the version should tell them something happened.

Ask explicitly, per release: *is this a PATCH or a MINOR?* Write the answer down. Don't default.

## 6. Release

Follow [release-checklist.md](release-checklist.md). Then:

- Advance the line's release branch (`release/v0.8.x`) to the new tag.
- Keep one release branch **per minor line** (`release/v0.6.x`, `release/v0.7.x`, …) so any released
  line can be returned to without archaeology. Tags pin the point; the branch is where you'd actually
  work.

---

## The principle underneath all of this

The product's value is a **courtroom-grade record of a meeting**. That makes a *silent wrong answer*
the worst possible failure — worse than a crash, worse than a lost recording, because the user cannot
know to distrust it.

Every rule above is downstream of that:

- Group related work, because entangled bugs hide in the gaps between fixes.
- Council before CI, because the tests you wrote cannot find the bug you didn't imagine.
- Measure on device, because "sounds fine" is how 54% silence padding passed for correct audio.
- Version honestly, because a user whose speaker labels just changed deserves to know.
