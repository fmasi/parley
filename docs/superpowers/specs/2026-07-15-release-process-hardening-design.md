# Release-process hardening — design spec

**Date:** 2026-07-15
**Status:** Approved (brainstorming), pending implementation plan
**Milestone:** v0.9.0, sub-project 1 of 4 (release-hardening → bug sweep → cleanup/#139 → feature)
**Closes:** #119. Directly addresses the #110 silent-feed-breakage class.
**Branch:** `feature/release-hardening` (off `main`; v0.9.0 dev line)

## Problem

The **local build/sign** path (`scripts/release.sh`) is already well-guarded: it asserts the tag
exists and HEAD is exactly on it, a clean working tree, the Keychain EdDSA key matches the app's
embedded `SUPublicEDKey` (#114), the stable (non-ad-hoc) signing identity (#114), the built
version, and it fixes the appcast enclosure-URL stamping bug (`fix_appcast_urls.py`).

Every remaining fragility is **after** the local build — and each is a *silent* failure, which is
the worst class for a courtroom-grade product that also depends on auto-update to ship fixes:

1. **No verification of the actually-published feed.** After `gh release create`, nothing checks
   that `releases/latest/download/appcast.xml` resolves, that "latest" points where it should,
   that enclosure URLs are live, or that signatures validate against the published zip. All of
   this is manual eyeballing (checklist step 6).
2. **`gh release create` is manual copy-paste** — the deltas glob, `--notes-file`, and the
   `--latest` flag are hand-entered every release. Implicit/wrong `--latest` is what caused #110.
3. **The two-line "latest" hazard is now live.** v0.9.0 develops on `main` (the Sparkle line);
   `release/0.8.x` is the frozen stable line. Nothing prevents a 0.8.x maintenance release from
   taking GitHub's "latest" and 404'ing the 0.9.x feed for every installed client.
4. **Release notes are authored twice** (Sparkle in-app HTML + GitHub markdown), with existence
   only half-enforced (`release.sh` warns for the HTML; nothing checks the GitHub md). They can
   drift or silently ship blank.

There is currently **no release/feed CI workflow at all** (only `test`, `claude-code-review`,
`claude`), so #119 is entirely unbuilt.

## Goals

- A silent feed break becomes a **loud, automatic failure** — on publish and on an ongoing schedule.
- The `gh release create` step is **guarded and scripted**, not hand-typed.
- A 0.8.x stable patch **cannot hijack "latest"** from the 0.9.x dev feed.
- Release notes are authored **once** and rendered to both destinations; never blank, never drifted.
- Signature verification runs in CI with **no secret** (public key only).

## Non-goals

- Automating the *cutting* of a release (build/sign stays device-local — the EdDSA private key
  lives only in the maintainer's login Keychain; not delegable to a headless runner).
- Changing the update UX (still always-prompt, never silent-install — a recording app must never
  interrupt a recording).
- Notarization / Developer ID signing (separate track; the app uses the stable self-signed identity
  today, and TCC-grant survival across updates depends on that identity being stable, not notarized).

## Components

Five focused units. Each has one purpose, a defined interface, and independent tests.

### 1. `scripts/render-release-notes` — single-source notes

- **Input:** `release/release-notes/<version>.md` (already the GitHub release body — becomes the
  single source of truth).
- **Output:** `release/updates/Parley-<version>.html` (Sparkle in-app notes pane).
- **How:** a **Python 3 stdlib-only** Markdown→HTML renderer (`scripts/render-release-notes.py`,
  matching `fix_appcast_urls.py`'s language, no pip dependency, no compile step) covering the subset
  release notes actually use (headings, paragraphs, `-`/`*` and ordered lists, links, bold/italic,
  inline code, code fences).
- **Wiring:** `release.sh` calls it *before* `generate_appcast`, so the HTML always exists and can
  never drift from the markdown.
- **Determinism:** same md → byte-identical HTML. **Golden-tested** (input md → expected HTML),
  matching the project's oracle/golden ethos.

### 2. `scripts/verify-release-feed.sh` — published-feed integrity verifier

Given a version/tag (defaulting to the newest published release), fetch the **real** published feed
and assert, failing loudly with a specific message on the first violation:

- `https://github.com/fmasi/parley/releases/latest/download/appcast.xml` returns 200 and parses as XML.
- `https://github.com/fmasi/parley/releases/latest` redirects to `/tag/v<version>` (i.e. "latest"
  resolves to the expected release).
- The newest `<item>`'s `sparkle:shortVersionString` (and enclosure filename) == `<version>`.
- Every `<enclosure url>` returns 200 (versioned URLs are live; catches the fix-appcast-urls regression).
- Each enclosure's `sparkle:edSignature` **validates against the downloaded bytes** using Sparkle's
  own Ed25519 verifier, with the public key read from `packaging/Info.plist`'s `SUPublicEDKey`
  (public-key-only; no secret needed).

**Signature-verify mechanism:** a small SwiftPM **executable target** (e.g. `verify-ed-signature`)
that reuses Sparkle's Ed25519 verification (Sparkle is already an SPM dependency), so CI verifies
with the *exact* algorithm the client uses. Swift is used here specifically because the verification
must go through Sparkle's own code; the shell script invokes it per enclosure.

- **Pure logic extracted and unit-tested:** version compare, "latest"-resolution parsing, XML/enclosure
  extraction.
- **HTTP + signature paths integration-tested** against a localhost fixture appcast (reuse
  `sparkle-dryrun.sh`'s local-server pattern), so CI exercises the verifier with **no real release**.

### 3. `scripts/publish.sh <version> [--line current|stable] [--dry-run]` — guarded publish

Wraps `gh release create` with the checklist's manual guards:

- **Preconditions:** tag exists and HEAD is on it; clean tree; `release/Parley-<version>.zip`,
  `release/updates/appcast.xml`, and `release/release-notes/<version>.md` all present and non-empty.
- **Safe deltas glob** (the documented non-empty-array bash pattern).
- **Explicit `--latest`, never implicit:** always passes `--latest=true|false`. `--line current`
  (the live Sparkle line, default) → `--latest=true`; `--line stable` (a `release/0.8.x` patch) →
  `--latest=false`. See §5.
- **`--dry-run`** prints the exact `gh` command instead of running it — the unit under test.
- On real publish, auto-invokes `verify-release-feed.sh <version>` so the maintainer gets an
  immediate pass/fail (CI/cron in §4 is the independent net).

### 4. `.github/workflows/release-feed.yml` — CI post-publish guard (closes #119)

- **Triggers:** `on: release: [published, edited]` **and** a daily `schedule: cron`. The cron
  catches the checklist's nightmare: a release later converted to draft/deleted silently reverts
  "latest" to an older release and stops all updates — no error, just nothing.
- **Runs** `verify-release-feed.sh` against the current published feed.
- **On failure:** red build + open (or update) a tracking issue, so a break that happens between
  releases still pages someone.
- **Secrets:** none — public-key verification only.

### 5. Two-line "latest" protection

The rule that directly serves the 0.8.x-vs-0.9.0 concern, encoded in two places:

- **`publish.sh`** requires an explicit `--line`; a `stable` release is published `--latest=false`
  and does **not** regenerate/overwrite the `appcast.xml` the `current` line serves.
- **`verify-release-feed.sh`** asserts "latest" points at the newest *current-line* release, so if a
  stable patch ever does steal "latest", the guard (and its cron) goes red immediately.
- **Docs:** `docs/release-checklist.md` collapses to: write `<version>.md` notes → `release.sh
  <version>` (now also renders HTML) → `publish.sh <version> [--line …]` (guarded, auto-verifies) →
  CI + cron watch the feed. The branch model is stated explicitly: `main` = 0.9.x dev / Sparkle
  line; `release/0.8.x` = frozen stable, critical backports only, published non-latest.

## Data flow

```
release/release-notes/<v>.md ──render──▶ release/updates/Parley-<v>.html
             │                                        │
             │                                (generate_appcast, in release.sh)
             ▼                                        ▼
   gh release body   ◀── publish.sh ──▶  release/updates/appcast.xml + zip + deltas
                              │
                              ▼ (auto, and independently via CI + daily cron)
                    verify-release-feed.sh ──▶ pass / LOUD fail (+ issue)
```

## Error handling

- Every guard fails **closed** with a specific, actionable message and a non-zero exit (matching
  `release.sh`'s existing style).
- The verifier reports the **first** violated invariant with the concrete offending value (URL,
  version, signature), so a failure names the fix — not "feed broken."
- `publish.sh` never leaves a half-published state silently: if `verify-release-feed.sh` fails right
  after publish, it surfaces loudly (the release exists but is flagged), which is strictly better
  than today's silent-broken-feed.

## Testing

| Unit | Test |
|---|---|
| render-release-notes | golden: md fixture → expected HTML (byte-identical) |
| verify-release-feed (pure) | unit: version compare, latest-resolution, enclosure/XML extraction |
| verify-release-feed (HTTP+sig) | integration vs. localhost fixture appcast (sparkle-dryrun server pattern) |
| Swift ed-signature helper | verifies a known-good signature; rejects a tampered zip |
| publish.sh | `--dry-run` asserts emitted `gh` flags for `--line current` and `--line stable` |
| fix_appcast_urls.py | existing `test_fix_appcast_urls.py` retained |

## Rollout

Lands as one PR to `main` (council-before-CI, then CI). It ships no product-code change, so no
device test is required beyond running `sparkle-dryrun.sh` once to confirm the notes rendering and
the local publish-dry-run behave. The CI feed guard proves itself on the first real v0.9.0 release.

## References

- Issues: #119 (CI feed-integrity guard), #110 (silent feed breakage), #114 (key/identity guards
  already in `release.sh`).
- Existing tooling: `scripts/release.sh`, `scripts/sparkle-dryrun.sh`, `scripts/fix_appcast_urls.py`
  (+ test), `docs/release-checklist.md`.
