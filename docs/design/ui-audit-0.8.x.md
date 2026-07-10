# Parley UI Audit — v0.8.x Revamp (Pass 1)

Audit of the 8 SwiftUI screens as of `feature/ui-revamp-0.8.x` fork point. Goal: identify
what reads as utilitarian/dated and where we diverge from the macOS HIG, so the revamp
fixes causes, not symptoms.

## Cross-cutting issues (every screen)

1. **No shared design vocabulary.** Paddings vary ad hoc (12/16/20/24), corner radii vary
   (3/6/12), section headers are styled three different ways (`.subheadline` secondary in
   SetupView, `Section("…")` in SettingsView, `.headline` in dialogs). Nothing is reused;
   every screen re-invents rows and badges (`PermissionRow` vs `PermissionSettingsRow` are
   near-duplicates).
2. **Emoji as iconography.** `🔴` and `⚠` inside menu items (MenuView criticals/warnings).
   First-party apps never do this — SF Symbols with semantic colors are the language.
3. **Ellipsis inconsistency.** `"Rename Speakers..."`, `"Settings..."`, `"Check for
   Updates..."`, `"Transcribing..."` use three periods; HIG wants the ellipsis character
   (`…`). SessionNameDialog already gets it right ("Choose…").
4. **Red is overloaded.** Red means record, error text, denied folder access, retry
   button, meter clipping. When everything can be red, the record affordance loses its
   meaning. Needs a reserved-color policy.
5. **Liquid Glass adoption is partial.** Three dialogs use `GlassBackgroundModifier`;
   Setup, CriticalAlert, and the menu itself don't participate in any material story.

## Per-screen

### 1. MenuView (hero — menu bar dropdown)
- **It's a plain `.menu`-style menu.** The app's entire personality is 9 text menu items.
  No status hierarchy, no elapsed-time display while recording, no visual difference
  between "idle" and "recording" beyond the toggle label and the tiny menu-bar icon.
- Status is faked with **disabled Buttons** (`Button("🔴 …"){}.disabled(true)`) — they
  render gray, look broken, and each needs a second "Dismiss" menu item, so an error eats
  3 rows of a menu.
- The recording toggle is a text item ("Start Recording") — the single most important
  action in the app has the same visual weight as "Open Recordings Folder".
- The mic item shows the device name with a `mic` icon but no affordance that it's
  changeable.
- No feedback during transcription beyond a disabled label; the progress string in
  `AppState.Phase.transcribing(progress:)` is never shown.
- **Verdict:** the jump to first-party requires `.menuBarExtraStyle(.window)` — a compact
  panel (Wi-Fi/Control-Center class) with a real status header, a prominent record
  button, live elapsed time, and hover-highlighted action rows. All logic (crash
  recovery, retry policy, mic reporting) is already view-local and carries over intact.

### 2. SetupView (hero — first run)
- Opens with an apology, not a welcome: "Parley needs a few permissions to work". First
  impression should sell the product's one promise — *everything stays on this Mac* —
  which currently appears nowhere.
- No brand moment: no app icon, no title hierarchy; it starts at `.title2`.
- Sections are bare secondary-text labels + `Divider()`s — reads like a debug form.
  System Settings / first-run assistants use grouped cards and icon tiles.
- Required vs Optional distinction is a one-word label, easy to miss; users don't know
  they can skip Calendar/Notifications.
- The Continue button is a default-size bordered button pinned bottom-right of a
  left-aligned column; the "gate" (all required granted + model ready) is invisible —
  users can't tell *why* Continue is disabled.
- Engine picker exposes internal jargon with zero context for a first-run user.

### 3. SettingsView
- **Ten sections in one 600pt scroll.** First-party apps tab this: General / Audio /
  Transcription / Summary / Advanced (`TabView` in the Settings scene).
- **Manual Save button in a toolbar** — macOS settings apply immediately; a Save button
  with "Saved" toast is a Windows pattern. (Changing apply-semantics touches
  config-write timing, so this is flagged for a later pass, done carefully.)
- Recording directory is a raw editable `TextField` — should be a path control + Choose…
  like SetupView already has.
- Copy is engineer-grade: "Context Overhead %", "0-indexed", "kbps" pickers without
  guidance.

### 4. RenameDialog
- Solid functionality (sample playback, channel-aware). Visual issues: rigid 120pt label
  column with magic `.padding(.leading, 124)`; `.quaternary` sample text is below
  readable contrast; borderless 16pt play/forward buttons are small targets; no subtitle
  explaining what the user is doing or where names end up.

### 5. SessionNameDialog
- Best of the current dialogs (glass, focus, sensible copy). Minor: no visual link to the
  calendar suggestion (a suggested name just appears pre-filled), Start button not
  visually primary beyond default-action tinting.

### 6. MicSwitchDialog
- Fine bones. Error text is bare red caption; switch-in-progress has no spinner, the
  button just stays disabled.

### 7. MicrophonePicker
- Level meter is genuinely good (System Settings-style). The "Microphone" label style
  (subheadline/secondary) is a third section-header variant; meter green/yellow/red
  thresholds are the one place tri-color is justified.

### 8. CriticalAlertDialog
- 40pt red triangle + headline is appropriately loud for its job. Dismiss button isn't
  prominent; no visual kinship with the rest of the app (no glass, different padding
  scale). Low priority.

## Status
Pass 1 redesigned MenuView + SetupView and established the shared components
(`DesignSystem.swift`). Pass 2 completed the remaining six items:
1. **SettingsView** — tabbed (General/Audio/Transcription/Summary/Permissions), folder
   path control, copy edit. Save semantics kept.
2. **RenameDialog** — card-per-speaker, larger play targets, readable sample text.
3. **SessionNameDialog + MicSwitchDialog** — calendar-suggestion hint + primary Start;
   switch spinner + orange errors.
4. **CriticalAlertDialog** — glass, prominent Dismiss, shared spacing.
5. **MicrophonePicker** — label aligned to the section-header token.
6. Sweep done: true ellipsis, Title Case, red-reservation policy verified.

## Deferred (deliberate, needs its own pass)
- **Settings instant-apply** — replacing the manual Save button touches config-write
  timing; discuss separately before changing.
- `silence_detection_enabled` / `silence_timeout_minutes` have **no consumer in the
  Swift codebase**, so the Settings section for them was dropped (maintainer decision,
  2026-07-10). The config keys still exist in `Config.swift`; removing those is the
  pipeline track's call.
