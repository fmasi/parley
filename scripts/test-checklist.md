# Test Checklist — v0.6.4 (capture trust) + v0.6.3 (PR #99)

## ⚠️ v0.6.4 — must device-test before commit (capture subsystem)
Build/install this worktree first: `cd /Users/fmasi/Git/Transcriber-v064 && python3 scripts/dev.py`
(Resets TCC — re-grant Screen Recording + Microphone on first launch.)

### #86 — verified in-place restart (the headline test)
- [ ] During a **capturable call** (Zoom/Teams/Meet), trigger an audio **route change** (connect/disconnect AirPods, switch output device). The SCStream stops and restarts in place.
- [ ] Remote audio **resumes** after the route change — confirm by transcript content; the restart is only trusted once real system buffers arrive again (≈4s liveness probe).
- [ ] A clean route change shows the transient banner: **"Audio device changed — recording resumed automatically."** and `system_audio_unrecovered` is **false**.

### #86 — system stream unrecoverable → mic preserved, no teardown
- [ ] Force a call where the **remote side can't be captured** at all (an **iPhone call answered on the Mac** is the known case) so the rebuilt stream delivers **no frames**.
- [ ] After the restart budget is exhausted, the menu shows: **"Remote audio couldn't be recovered — only your microphone is recording."**
- [ ] Your **mic keeps recording** the whole time — the session is NOT stopped/finalized (no crash-recovery relaunch).
- [ ] Stop → transcript `metadata.capture_provenance.system_audio_unrecovered` is **true**, and a `.diag.jsonl` exists (it's an anomaly).

### #86 — no false success on a good call
- [ ] Record a **normal capturable call**. Remote audio present throughout.
- [ ] **No** unrecoverable warning appears; `system_audio_unrecovered` is **false**.

### #101 — provenance no longer leaks across sessions
- [ ] Record **two short sessions back-to-back** (the app stays running between them).
- [ ] The **second** transcript's `capture_provenance` shows `route_changes: 0`, `anomaly_count: 0` (its own clean numbers) — NOT the first session's tallies.
- [ ] The second session's `.diag.jsonl` (if written) contains **only** that session's events, none from the first.

---

## ⚠️ Must device-test before tagging v0.6.3
These three change **runtime behavior** and can't be validated by unit tests.

### #59 — single-stream recordings now archive to .m4a (no WAV left behind)
The behavior change: a recording with **no mic** (mic permission off, or system-audio-only) used
to leave raw `.wav` files on disk forever. Now every chunk flushes to `.m4a`.
- [ ] Record a **system-audio-only** session (deny/disable mic). Stop.
- [ ] The recording folder contains a `.m4a` and **no leftover `.wav`** files.
- [ ] The `.m4a` plays back and transcribes correctly.
- [ ] **Failure fallback:** if archival fails (rare), the `.wav` is kept (never deleted with no `.m4a` replacement) — check log for an archive-failure warning if you can force one.

### #60 — echo dedup across crash-recovery segments
Internal embedding change (accumulate + centroid). Verify it didn't regress normal echo removal.
- [ ] Record with audio on **speakers** (no headphones), speak a few sentences over it.
- [ ] Your speech is preserved; bleed removed (`echo_segments_removed > 0` in JSON metadata).
- [ ] Bonus (crash-recovery): after a session that survived a crash, echo dedup still runs and removes nothing it shouldn't (no real local speech wrongly dropped).

### #49 — summary uses the recording date, not "today"
- [ ] Summarize a transcript (ideally one recorded on a **previous day**).
- [ ] The summary's date reflects when it was **recorded**, not when the summary ran.

---

## Quick UI / behavior checks (this PR)
- [ ] **#57** Settings → Summary: fill in context-overhead % and max-output-tokens, Save, reopen Settings → both **persist** (previously dropped).
- [ ] **#33** Settings shows an **About** section with version + build number.
- [ ] **#55** Multi-chunk dual-stream transcript: speaker labels read `Local Speaker N` / `Remote Speaker N` — **never** `Local Local Speaker N`.
- [ ] **#56** Multi-chunk transcript: segments are in correct **time order** end to end.
- [ ] **#44/#45** Delete a file from the FluidAudio cache, relaunch → a **user-visible** warning (launch notification + red indicator in Settings), and the log reports **both** missing and corrupt files (not just the first problem).
- [ ] **#53** During a recording, `log stream --predicate 'subsystem == "eu.fmasi.parley"'` shows speaker names / file paths / session names as `<private>` — **not** in clear text.
- [ ] **#61** Long meeting with a few well-spaced XPC restarts → no "crashed repeatedly" lockout.
- [ ] **#62** `Parley transcribe -i file.m4a --debug` exits cleanly even if the log stream couldn't start (no crash on exit).

---

## Regression (always)
- [ ] Start recording → stop → transcription completes
- [ ] Multi-chunk recording merges to a single `.m4a`, plays back with no gaps
- [ ] Dual-stream `.m4a` is stereo (L=mic, R=system); source WAVs deleted after archival
- [ ] Rename dialog works; play button plays correct channel per speaker
- [ ] Summary auto-generates (`-summary.md`) when an LLM endpoint is configured
- [ ] App survives quit + relaunch (LaunchAgent)
