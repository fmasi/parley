# Release checklist (Sparkle auto-update)

One-time-per-release manual steps for publishing a Parley update. Assumes `#98`/`#100` (Sparkle
wiring + monotonic `CFBundleVersion`) are already merged to `main`.

## Prerequisites (one-time, already done as of this doc)
- EdDSA signing key pair generated (`generate_keys`), private key in the login Keychain,
  `SUPublicEDKey` in `packaging/Info.plist`.
- `SUFeedURL` points at `https://github.com/fmasi/parley/releases/latest/download/appcast.xml`.

## Per-release steps

1. **Merge everything intended for this release to `main`**, and make sure `main` is green (test +
   CodeQL + resolved threads — see `docs/pipeline.md` / project CI gotchas).

2. **Tag the release** from `main`:
   ```bash
   git checkout main && git pull
   git tag v0.7.0
   git push origin v0.7.0
   ```
   `CFBundleShortVersionString` comes from this tag (minus the `v`); `CFBundleVersion` is the
   total commit count (`git rev-list --count HEAD`) — monotonically increasing, never resets.

3. **Build, archive, and sign**:
   ```bash
   bash scripts/release.sh 0.7.0
   ```
   This builds `--release`, archives `dist/Parley.app` to `release/Parley-0.7.0.zip` (symlinks
   preserved — required for `Sparkle.framework`'s internal `Versions/Current` symlink), and runs
   Sparkle's `generate_appcast` against `release/updates/` to (re)sign every release ever placed
   there and (re)generate `release/updates/appcast.xml` + any `*.delta` files. `release/` is
   git-ignored — this is release-machine output, not source.

4. **Write release notes — two distinct files, two distinct purposes:**
   - `release/release-notes/0.7.0.html` — shown **inside Sparkle's update dialog**, referenced by
     `sparkle:releaseNotesLink` in the generated appcast item (check `release/updates/appcast.xml`
     for the exact expected filename/path if `generate_appcast` didn't find one and used a fallback).
   - `release/release-notes/0.7.0.md` — the **GitHub release page body**, passed to `gh release
     create --notes-file` below. Can be the same content in markdown form; they don't have to match
     word-for-word, but should describe the same release.

5. **Create the GitHub release**, uploading the zip, the appcast, and any delta files:
   ```bash
   # No delta files exist until the second release ever cut — glob only if the array is non-empty,
   # otherwise gh would be passed the literal unexpanded string "release/updates/*.delta" and fail.
   deltas=(release/updates/*.delta)
   [[ -e "${deltas[0]}" ]] || deltas=()

   gh release create v0.7.0 \
     release/Parley-0.7.0.zip \
     release/updates/appcast.xml \
     "${deltas[@]}" \
     --title "Parley 0.7.0" \
     --notes-file release/release-notes/0.7.0.md
   ```
   Because `SUFeedURL` uses `releases/latest/download/appcast.xml`, this release must be GitHub's
   "latest" release for the feed URL to resolve to it (true for the newest non-draft, non-prerelease
   release by default).

6. **Verify the update actually works** by installing the *previous* released build (or a build from
   before this tag) and using **Check for Updates…** from the menu bar. Confirm:
   - The update is detected (new-version dialog appears with these release notes).
   - The EdDSA signature validates (Sparkle would show a corrupt-update error otherwise).
   - Install & Relaunch works, and the relaunched app reports the new version in Settings/About.

## Notes
- Never silent-install: the app does not set `SUAutomaticallyUpdate`, so every update prompts —
  intentional for a recording app (never interrupt an active recording).
- The private signing key lives only in the maintainer's login Keychain; back up an exported copy
  (`generate_keys -x`) somewhere safe outside this repo, never commit it (`.gitignore` blocks
  `*.pem` / `sparkle_private_key*` already).
- `release/updates/` is a **persistent accumulation folder across releases**, not per-release scratch
  space — keep every prior release's archive in it so `generate_appcast` can keep generating delta
  patches between versions.
