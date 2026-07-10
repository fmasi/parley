# Parley Design Language — "Quiet Confidence" (v0.8.x)

Parley records the most sensitive thing on your Mac — your conversations — and never
lets them leave. The UI must *feel* like that promise: calm, precise, unhurried,
nothing flashy. Reference points: Voice Memos (recording language), Things (calm
hierarchy), System Settings (rows, icon tiles), Control Center panels (menu bar
presence). Everything is stock SwiftUI + SF Symbols + semantic colors — the design is
in the restraint, not in custom chrome.

## Voice
- **Affirmative privacy.** Say what the app does, not what it needs: "Everything stays
  on this Mac", not "Parley needs a few permissions".
- Controls in Title Case ("Start Recording"); descriptions in sentence case.
- True ellipsis `…` everywhere an action opens further UI.
- Calm in errors: state what happened and what was saved. No exclamation marks; emoji
  never (SF Symbols carry all iconography).

## Type scale (SF Pro via system styles — never fixed sizes except the timer)
| Token | Style | Use |
|---|---|---|
| Hero | `.title.bold()` | Setup/welcome headline only |
| PanelTitle | `.headline` | Panel/dialog titles |
| SectionHeader | `.footnote.weight(.semibold)`, secondary, sentence case | Card/group headers |
| Row | `.body` | Row labels, menu actions |
| Detail | `.footnote`, secondary | Row descriptions, hints |
| Status | `.subheadline`, secondary | Live status lines |
| Timer | `.title3.monospacedDigit()`, `.rounded` design | Elapsed recording time |

## Spacing & shape (4pt grid)
- Menu panel padding **12**; dialog padding **20**; window (Setup) padding **28**.
- Row: vertical **6**, horizontal **8**; icon column fixed **20pt** wide, `spacing: 10`.
- Section gap **16**; intra-card row gap **10**.
- Corner radii: **6** small controls · **10** cards/banners · **12** panels (matches
  `GlassBackgroundModifier`).
- Panels: menu panel width **320**; dialogs **380–400**; Setup **460**.

## Color & material
- **Semantic colors only** — no hex, no custom palette. Adapts to dark mode and accent
  for free.
- **Red is reserved**: record/stop and truly critical failures. Errors elsewhere use
  `.orange` (warning) or plain secondary text with an orange symbol. The one exception:
  level-meter clipping (system convention).
- Green = granted/ready (`checkmark.circle.fill`) only.
- Accent color = interactive emphasis (Continue, links). Never decorate with it.
- Cards/banners: `.quinary` fill, radius 10 — quiet grouping, System Settings-adjacent.
- **Liquid Glass** (macOS 26) via existing `GlassBackgroundModifier` on floating panels,
  `.regularMaterial` fallback on 15 (docs/gotchas.md #14, #20). Don't fight the
  window-style MenuBarExtra's own backing material.

## Iconography (SF Symbols only)
- Rows: `.symbolRenderingMode(.hierarchical)`, secondary foreground, fixed 20pt frame.
- Setup uses **icon tiles** (System Settings style): 26×26, radius 6, white symbol on a
  muted semantic color — the strongest "first-party assistant" signal we can send.
- Recording states: `record.circle` (idle CTA) · `stop.fill` (recording) ·
  `waveform` + spinner (transcribing). Menu bar icon logic stays in `AppState`.

## Motion
- One live element per screen, max. Recording gets a soft-pulsing red dot
  (`.easeInOut(1s).repeatForever`) + ticking timer; everything else is static.
- State changes animate with default SwiftUI transitions; nothing bounces.

## Components (`TranscriberApp/Views/DesignSystem.swift`)
| Component | Role |
|---|---|
| `MenuActionRow` | Hover-highlighted action row for the menu panel (icon + title, plain button, 0.08 primary hover wash) |
| `IconTile` | 26×26 rounded color tile with white SF Symbol (Setup rows) |
| `StatusDot` | 8pt dot, pulses while recording |
| `AlertBanner` | Quinary card, severity icon (orange/red), message + ⌫ dismiss — replaces disabled-Button status rows |
| `recordingTimerString(from:to:)` | h:mm:ss / mm:ss formatting for the live timer |

## The menu bar presence (decision)
`MenuBarExtra` switches from `.menu` to **`.window`** style: a 320pt panel with a status
header (name + state + live timer), a prominent record/stop button, mic row, alert
banners, then hover rows for secondary actions. This is the single change that moves
Parley from "script with a menu" to "app with a presence" — and it's where every recent
first-party menu bar surface (Wi-Fi, Battery, Now Playing) lives.
