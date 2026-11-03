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
> deliberately absent — the sequence is the point. Each stage is a
> [milestone](https://github.com/fmasi/parley/milestones) holding its issues.

---

## Shipped
- **`v0.9.0` · Clean base + provable trust** — a recording never fails silently: a silent mic, a lost
  permission, a gap or a failed write raises an alarm while it lasts; echo detection; a speaker count
  you can correct; secrets in the Keychain
- **`v0.10.0` · Meetings that run themselves** — Parley notices a meeting starting and offers to record
  it (and to stop when it ends); the Core Audio tap captures Continuity, iPhone Mirroring and app calls
- **`v0.11.0`** — a quarter less memory and time per recording; optional mic echo cancellation that
  never touches the recording itself

## Now — `v0.11.1` · Airgap fixes
- **Models change only when you ask** — a damaged model is reported, never silently deleted and
  re-downloaded during a transcription
- **Recognised words stay off the console** — the speech engine's own logging is held to Parley's
  privacy rules

## Next — `v0.12` · Accuracy
Better words and better speaker attribution. Each change ships only when a benchmark proves it
([evaluation](docs/fluidaudio-evaluation-2026-10.md)).

- **A more accurate default speech model** — Parakeet Ultra and the corrected v3 encoder, measured
  against today's model on word error rate and memory
- **Custom vocabulary** — names and jargon, seeded from the calendar event, so the people in the
  meeting are spelled right
- **Every language out of the box** — FluidAudio-native Chinese, Japanese and Korean engines with
  automatic language routing, replacing the manual setup Apple's engine needs today
- **Echo that's judged, not guessed** — tell which side is the copy, judge echo before small
  clusters are merged away, and decide whether echo cancellation should be on by default
- **Faster re-detect** — correct a speaker count without re-running the whole analysis

## Then — `v0.13` · Speaker memory
- **Name someone once** — Parley recognises them in later meetings, on this Mac only (voice prints
  are biometric data: stored locally, deletable, never shared)
- **A rename dialog built for it** — pick across sessions, with better voice samples
- **Speaker identity the compiler checks** — one speaker type instead of matching strings

## Later — `v0.14` · The private context layer
Parley as a context source your agents can query — the part no cloud note-taker can safely offer.

- **A typed transcript** — one schema that every reader and writer shares, the foundation for the rest
- **Agent-queryable meeting history (RAG + MCP)** — search and retrieve across your own meetings
  through an MCP interface, fully on-device
- **Meeting threads** — follow a topic across a recurring meeting series
- **Grounded summaries** — decisions and action items that cite the lines they came from
- **Provable provenance** — tamper-evident transcripts; an auditable guarantee that a recording never
  left the machine

## Not yet scheduled
- **Turnkey on-device summaries** — Apple's on-device models, no endpoint to configure
- **Long meetings in any model** — summarise transcripts larger than the model's context
- **Summary templates** per meeting type, and summaries that retry instead of failing

---

## Always true
- **Private by construction** — no account, no upload, no telemetry
- **Open source** (AGPL-3.0) on **open models**
- **Easy to trust and install** — signed, with Homebrew distribution planned

*Curious where a specific feature sits? The [issues](https://github.com/fmasi/parley/issues) are
grouped under the milestones above.*
