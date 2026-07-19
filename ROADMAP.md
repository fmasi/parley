# Parley — Roadmap

Parley is private, on-device meeting transcription for Apple Silicon — and, increasingly, a
**private context layer that your AI agents can draw on.** Everything is captured on your Mac, on
open models, with nothing phoning home. It's one half of a two-piece stack: **parley** for calls and
meetings, **[mailrag](https://github.com/fmasi/mailrag)** for email. A private, open record of what
was actually said — kept on-device, so you (and your agents) get total recall without renting your
memory to anyone.

**By humans. For agents.**

> This roadmap is directional, not a commitment. Shipped work lives in the
> [releases](https://github.com/fmasi/parley/releases); this is where things are heading. Dates are
> deliberately absent — the sequence is the point.

---

## Now — `v0.9.0` · Clean base + provable trust
Tighten and audit the core before widening it. A credible base is worth more than more surface area.

- **Security & privacy hardening** — secrets moved to the Keychain; identifying data scrubbed from logs
- **Deep code-quality pass** — remove dead code and duplication (success metric: *net lines removed*)
- **Automatic language routing** — pick the right engine per language with zero setup, so non-Latin
  scripts work out of the box
- **Self-checking transcripts** — the app flags its *own* low-confidence speaker separation rather
  than hiding it (`separation: UNRELIABLE`)
- **Finish the crash-recovery / chunked-pipeline bug sweep**

## Next — `v0.10` · Meetings that run themselves
Remove the manual steps around a recorded meeting.

- **Automatic meeting detection** — recording starts when a call starts; no button to remember
- **Acoustic echo cancellation** — clean speaker-mode calls (no headphones required) handled at
  capture time via Apple's VoiceProcessing IO, with noise suppression along for the ride
- **Turnkey on-device summaries** — zero-setup summarisation on Apple's on-device models; no external
  endpoint to configure
- **Cross-session speaker memory** — name someone once, and Parley recognises them in later meetings

## Later — `v0.11` · The private context layer
Parley as a context source your agents can query — the part no cloud note-taker can safely offer.

- **Agent-queryable transcripts** — an MCP interface over your own meeting history, fully on-device
- **Wider capture** — iPhone Mirroring and app-call (e.g. WhatsApp) audio, extending the Core Audio tap that already captures Continuity calls
- **Provable provenance** — tamper-evident transcripts; an auditable guarantee that a recording never
  left the machine

---

## Always true
- **Private by construction** — no account, no upload, no telemetry
- **Open source** (AGPL-3.0) on **open models**
- **Easy to trust and install** — signed, with Homebrew distribution planned

*Curious where a specific feature sits? The [issues](https://github.com/fmasi/parley/issues) are
grouped under the epics above.*
