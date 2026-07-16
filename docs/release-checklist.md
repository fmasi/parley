# Release checklist (Sparkle auto-update)

Publishing a Parley update. The build/sign step is device-local (the EdDSA private key lives only
in the maintainer's login Keychain); everything else is guarded by scripts and CI.

## Branch model (important)

- **`main` = the live 0.9.x development / Sparkle line.** Releases cut from here are published on the
  **current** line and take GitHub's "latest" — that's what `SUFeedURL`
  (`releases/latest/download/appcast.xml`) resolves to.
- **`release/0.8.x` = the frozen stable line.** Critical backports only; big refactors never land
  here. A 0.8.x maintenance release is published on the **stable** line (`--line stable` →
  `--latest=false`) so it cannot hijack "latest" from the 0.9.x feed and silently 404 it for every
  installed client (#110).

## Prerequisites (one-time)
- EdDSA signing key pair generated (`generate_keys`), private key in the login Keychain,
  `SUPublicEDKey` in `packaging/Info.plist`. Back up an exported copy (`generate_keys -x`) outside
  the repo; never commit it (`.gitignore` blocks `*.pem` / `sparkle_private_key*`).
- `SUFeedURL` → `https://github.com/fmasi/parley/releases/latest/download/appcast.xml`.
- Python 3 and `swift build` have been run once (Sparkle SPM tools resolved under `.build/`).

## Per-release steps

1. **Merge everything for this release to `main`** and confirm it's green (test + CodeQL + resolved
   review threads).

2. **Write the release notes — one file, the single source of truth:**
   ```bash
   $EDITOR release/release-notes/<version>.md    # e.g. release/release-notes/0.9.0.md
   ```
   This becomes both the GitHub release body **and** (rendered to HTML by `release.sh`) the Sparkle
   in-app notes pane — they can no longer drift or ship blank.

3. **Tag from `main`:**
   ```bash
   git checkout main && git pull
   git tag v<version> && git push origin v<version>
   ```

4. **Build, sign, generate the appcast:**
   ```bash
   bash scripts/release.sh <version>
   ```
   Builds `--release`, archives to `release/Parley-<version>.zip` (symlinks preserved), **renders
   `release/updates/Parley-<version>.html` from step 2's markdown**, and runs `generate_appcast`
   (signing every archive in `release/updates/` with the Keychain key and regenerating
   `appcast.xml` + `*.delta`). Its existing guards abort on a dirty tree, a tag mismatch, an
   ad-hoc-signed build, or a Keychain-key/`SUPublicEDKey` mismatch.

5. **Publish (guarded):**
   ```bash
   bash scripts/publish.sh <version> --line current  # the live 0.9.x line — takes latest
   bash scripts/publish.sh <version> --line stable    # a 0.8.x maintenance patch — NOT latest
   ```
   `--line` is **required** (no default): forgetting it on a 0.8.x patch would silently take
   "latest" and 404 the 0.9.x feed (#110). `publish.sh` checks the required artifacts exist, globs
   any deltas safely, passes an **explicit** `--latest`, and on success runs
   `scripts/verify-release-feed.sh` immediately to confirm the published feed is intact.

6. **The feed is watched automatically.** `.github/workflows/release-feed.yml` re-verifies the
   published feed on every release event **and daily** (the cron catches a release later converted
   to draft/deleted silently reverting "latest"), opening an issue if it ever breaks. To check by
   hand any time:
   ```bash
   bash scripts/verify-release-feed.sh [<version>]
   ```

## Offline pre-flight (optional but recommended)

`bash scripts/sparkle-dryrun.sh` stages this build as an older+newer pair, serves a signed appcast
over localhost, and walks Check-for-Updates → download → EdDSA-verify → install → relaunch,
confirming TCC permissions (Microphone, Screen Recording) survive the update (#114.3). Fully offline;
no throwaway GitHub release needed.

## Notes
- Never silent-install: the app does not set `SUAutomaticallyUpdate`; every update prompts —
  intentional for a recording app (never interrupt an active recording).
- `release/updates/` is a **persistent accumulation folder across releases** (git-ignored), so
  `generate_appcast` can keep producing delta patches. If it's empty on a fresh machine, releases
  still work (Sparkle serves the full zip); repopulate it by re-downloading prior releases' zips
  from their GitHub release pages to resume deltas.
- `CFBundleShortVersionString` comes from the tag (minus `v`); `CFBundleVersion` is the HEAD
  commit's committer timestamp (`git show -s --format=%ct HEAD`) — monotonic across branches, so a
  0.8.x hotfix never gets a lower build number than a 0.9.x release (#110).
