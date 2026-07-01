# Release checklist (Sparkle auto-update)

One-time-per-release manual steps for publishing a Parley update. Assumes `#98`/`#100` (Sparkle
wiring + monotonic `CFBundleVersion`) are already merged to `main`.

## Prerequisites (one-time, already done as of this doc)
- EdDSA signing key pair generated (`generate_keys`), private key in the login Keychain,
  `SUPublicEDKey` in `packaging/Info.plist`.
- `SUFeedURL` points at `https://github.com/fmasi/parley/releases/latest/download/appcast.xml`.
- Python 3 available (`python3 --version`) — used by `scripts/release.sh` for the appcast URL
  fixup; ships with Xcode / Command Line Tools.

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

3. **Write the Sparkle in-app release notes BEFORE building** — `generate_appcast` only embeds a
   `sparkle:releaseNotesLink` in an entry if the matching HTML file already exists at signing time
   (step 4 runs `generate_appcast` against `release/updates/`, so this must happen first or every
   entry ships with a blank notes pane in Sparkle's update dialog):
   ```bash
   mkdir -p release/updates
   $EDITOR release/updates/Parley-0.7.0.html   # same base filename as the zip release.sh will create
   ```

4. **Build, archive, and sign**:
   ```bash
   bash scripts/release.sh 0.7.0
   ```
   This builds `--release`, archives `dist/Parley.app` to `release/Parley-0.7.0.zip` (symlinks
   preserved — required for `Sparkle.framework`'s internal `Versions/Current` symlink), and runs
   Sparkle's `generate_appcast` against `release/updates/` to (re)sign every release ever placed
   there and (re)generate `release/updates/appcast.xml` + any `*.delta` files, picking up the HTML
   from step 3 for `sparkle:releaseNotesLink`. `release/` is git-ignored — this is release-machine
   output, not source.

   Separately, write `release/release-notes/0.7.0.md` — the **GitHub release page body**, passed
   to `gh release create --notes-file` below. Distinct file, distinct purpose (Sparkle's dialog vs.
   the GitHub releases page); can be the same content in markdown form, doesn't need to match the
   HTML word-for-word.

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
   - **The GitHub release is published as non-draft, non-prerelease** — `SUFeedURL` resolves
     `releases/latest/download/appcast.xml` to whichever release currently holds the "latest"
     designation. If a future release is ever un-published (converted back to draft, or deleted
     and recreated), "latest" silently reverts to the previous release and every installed client
     stops seeing new updates until it's fixed — no error, just quietly nothing happening.
   - Spot-check `release/updates/appcast.xml`: every `<enclosure url="...">` is a versioned GitHub
     download URL (`releases/download/v0.7.0/...`, each pointing at *its own* release's tag) —
     `scripts/release.sh` fixes this automatically after `generate_appcast` runs (which otherwise
     stamps the current release's tag onto every accumulated entry), but it's cheap to eyeball.
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
