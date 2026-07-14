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

## 3. Then CI, and monitor it — but bound the review loop

Push, open the PR, watch the checks. Resolve what's *pertinent*. The load-bearing word is
pertinent, because an automated reviewer has a structural bias you must counter:

**The review bot only ever adds code.** Its incentive is to find something to say, and "find
something" almost always resolves to "add a guard / handle this edge / distinguish that case."
It will never tell you to delete a line or that the change is simpler than you made it. Comply
uncritically and a bug fix grows into defensive sprawl across many rounds — and more lines is
more surface for the *next* bug, which is the disease, not the cure. With an AI author this is
acute: the agent will cheerfully generate code for every suggestion.

So apply a filter, the same one you'd apply to your own code:

- **A finding is fixed only if it reduces expected harm more than the code it adds.** "Cheap to
  fix" is not the bar. Net-negative lines, or a real bug, is the bar.
- **If a finding cannot be reduced to a test that goes RED without the fix, it is an opinion, not
  a defect** — and opinions must not cost lines. Reply, don't patch.
- **The severity should be falling each round.** If round N is finding smaller things than round
  N-1, the bot is converging — stop when it reaches nitpicks, don't chase it to zero. Endlessly
  satisfying a reviewer that cannot say "enough" is how a PR never merges.

CI itself must be able to catch the class of bug you just fixed. If it can't, **that is part of
the fix** — the `diarization-guard` job exists because the regression tests skipped silently in
CI, so the suite reported green while asserting nothing.

**What CI cannot cover:** anything needing real audio hardware — the capture path, Bluetooth/HFP
behaviour, ScreenCaptureKit, the Core Audio tap. These require device validation on a real Mac,
and the measurements belong in the commit message.

## 3a. Then a simplification pass — the only step that removes

Nothing above removes code. The council adds findings, the bot adds guards, the author adds
features. Before merge, run one pass whose *only* permitted output is deletion or consolidation:
duplicated logic collapsed, dead branches removed, a guard that a type could enforce instead,
three checks that were really one. If it can't be made smaller, that's a fine answer — but the
question has to be asked by someone, because no other step in the loop asks it.

Less code is the goal, not a side effect. Every line is a liability the product carries forever.

## 4. Device-test before merge

Anything touching capture, audio, or the pipeline gets tested on real hardware with a real recording
before merge. State the measurement, not the impression: *"56.7% zero-padding → 5.8%"*, not *"sounds
better"*.

## 5. Decide the version deliberately

Pre-1.0, we use `0.MINOR.PATCH`, and the numbers are **cheap signals, not a spec**. The codebase is
young and moves fast; a rule that bumps MINOR on every behaviour change inflates it until it means
nothing — and a version number that goes up on everything communicates nothing.

| bump | when |
|---|---|
| **PATCH** (`0.8.1` → `0.8.2`) | Fixes. **Including fixes that change output** — restoring behaviour to what it should always have been is a fix, not a feature. Also: internal tooling, diagnostic config knobs, tests, docs. |
| **MINOR** (`0.8.x` → `0.9.0`) | Something **meaningful** shipped: a real capability, a milestone, a change of direction. The kind of thing you'd put in a changelog headline for its own sake. |

**The version number is a weak channel; don't overload it.** When a *fix* materially changes what
users' transcripts say, the right response is not to spend a minor version on it — it is to say so
loudly where they will actually see it:

- Lead the release notes with the user-visible consequence, in plain words, including what they
  should do about it ("re-run affected recordings").
- For a fix that changes the recording pipeline itself, consider Sparkle's
  `minimumAutoupdateVersion` so the update prompts an explicit **Install** rather than silently
  swapping the pipeline under someone mid-meeting.

Ask explicitly, per release: *is this meaningful, or is it a fix?* Write the answer down. Don't default.

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
