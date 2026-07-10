# Test Checklist — v0.8.x UI Revamp (all 8 screens)

Build/install this tree first: `python3 scripts/dev.py`
(Resets TCC — re-grant Screen Recording + Microphone on first launch.)

Everything here is a visual/UX pass — the pipeline is untouched. Compare
against docs/design/design-system-0.8.x.md ("Quiet Confidence") when in doubt.

## Menu bar panel (MenuView — from Pass 1, re-check after rebase)
- [ ] Panel opens as a 320pt window-style panel, not a text menu.
- [ ] Idle: green dot, prominent red Start Recording button, hover-highlight on action rows.
- [ ] Recording: pulsing red dot, live mm:ss timer ticking, Stop button.
- [ ] Transcribing: spinner in header, record button disabled.
- [ ] Warnings/criticals appear as dismissible banners, not disabled menu items.

## Setup window (SetupView — from Pass 1, re-check after rebase)
- [ ] Opens with app icon + "Welcome to Parley" + privacy line, grouped cards with icon tiles.
- [ ] Continue stays disabled with an explanatory footnote until required permissions + model are ready.
- [ ] Folder Choose… works; denied folder shows orange guidance, not red.

## Settings window (NEW — tabbed)
- [ ] Five tabs render with toolbar-style icons: General / Audio / Transcription / Summary / Permissions.
- [ ] Window resizes sensibly when switching tabs; no clipped content.
- [ ] General: Recording Folder shows a ~-abbreviated path + Choose… panel (no raw TextField).
- [ ] Save bar at the bottom of every tab; ⌘S saves; "Saved" appears ~2s; edits persist to config.json only after Save.
- [ ] Transcription: engine switch to Parakeet when model uncached → "Model will download … when you save"; Save triggers download with progress; failure shows orange (not red).
- [ ] Permissions tab: granted = green check; not-determined = Grant; denied = Open Settings (deep-links Privacy pane).
- [ ] Summary: LM Studio provider reveals the Context section; empty fields show "Model default" prompts.

## Rename Speakers dialog (NEW — cards)
- [ ] One card per speaker: label top-left, sample counter + play/next top-right, name field, quoted sample text.
- [ ] Sample text is readable (secondary, not faint quaternary).
- [ ] Play/next buttons are comfortably clickable; playback still channel-correct (local=L, remote=R).

## Session name dialog
- [ ] With a calendar meeting in range: field pre-filled + "Suggested from your calendar" caption; typing your own name swaps the caption to the timestamp hint.
- [ ] Start Recording is the visually primary (filled) button.

## Mic switch dialog (during recording)
- [ ] Switch shows a spinner + "Switching…" while in flight.
- [ ] A failed switch shows an orange warning label, not red.

## Critical alert
- [ ] Sits on the same glass/material as the other dialogs; Dismiss is a prominent filled button; red triangle unchanged.

## Cross-cutting
- [ ] Every "opens further UI" label uses a true ellipsis (…): Settings…, Rename Speakers…, Choose…, Check for Updates…, Switching…
- [ ] Red appears ONLY for: record/stop affordances, recording timer/dot, critical alerts, destructive rows (Quit is not red), meter clipping.
- [ ] Dark mode: run the full pass once in dark mode — cards, glass, and meter must all adapt.

## Regression (always — do not trim; these are standing gates, not per-feature tests)
- [ ] Start recording → stop → transcription completes
- [ ] Multi-chunk recording merges to a single `.m4a`, plays back with no gaps
- [ ] Dual-stream `.m4a` is stereo (L=mic, R=system); source WAVs deleted after archival
- [ ] Rename dialog works; play button plays correct channel per speaker
- [ ] Summary auto-generates (`-summary.md`) when an LLM endpoint is configured
- [ ] App survives quit + relaunch (LaunchAgent) — `LaunchAgentManager.uninstall()` is reachable from both MenuView and SetupRequiredPanel, so exercise Quit from each
- [ ] **Privacy:** during a recording, `log stream --predicate 'subsystem == "eu.fmasi.parley"'` shows names/paths as `<private>`
- [ ] **#86 (SCK default path):** mid-recording output switch (speakers → AirPods) while System Audio Capture is set to Screen Recording → stream restarts in place, remote audio resumes, no "unrecovered" warning in the menu bar panel.
