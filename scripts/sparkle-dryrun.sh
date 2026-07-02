#!/usr/bin/env bash
# scripts/sparkle-dryrun.sh — offline end-to-end Sparkle auto-update dry-run (#114.3).
#
# Proves the real download → EdDSA-verify → install → relaunch path that has never been exercised,
# AND that TCC permissions (Microphone, Screen Recording) survive an update when both builds share
# the stable signing identity.
#
# HOW IT WORKS
#   Builds ONE release from the current worktree, then stages it as two versions signed with the
#   SAME stable cert, differing only in version/build number:
#     OLD = 0.7.0  — installed to /Applications, its SUFeedURL repointed at a localhost appcast
#     NEW = 0.7.1  — served as the available update
#   Serves an EdDSA-signed appcast over http://localhost so Sparkle in the OLD app finds NEW,
#   downloads it, verifies it, installs it, and relaunches — entirely on this machine, no network,
#   no throwaway GitHub release.
#
#   Both builds are the CURRENT (council) code — the version delta exists only to give Sparkle
#   something newer to offer. After the update you exercise the shipping build's real behavior
#   (single-instance #109, tap audio #111, speaker labels #113) on the relaunched NEW app.
#
# USAGE
#   bash scripts/sparkle-dryrun.sh          # build + stage + serve, then print the manual steps
#   bash scripts/sparkle-dryrun.sh --stop   # stop the local feed server and clean up staging
#
# This CLOBBERS /Applications/Parley.app (installs OLD there). That's intended for the test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

PORT=8477
DRYRUN_DIR="release/dryrun"
UPDATES_DIR="$DRYRUN_DIR/updates"          # served over http; holds appcast.xml + NEW zip
STAGE_DIR="$DRYRUN_DIR/stage"
PIDFILE="$DRYRUN_DIR/server.pid"
IDENTITY="Parley Self-Signed"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
FEED_URL="http://localhost:$PORT/appcast.xml"

# ── --stop: tear down ─────────────────────────────────────────────────────────
if [[ "${1:-}" == "--stop" ]]; then
    if [[ -f "$PIDFILE" ]] && kill "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Stopped local feed server (pid $(cat "$PIDFILE"))."
    else
        echo "No running feed server found."
    fi
    rm -f "$PIDFILE"
    echo "Staging left at $DRYRUN_DIR (rm -rf it when done). /Applications/Parley.app is the tested build."
    exit 0
fi

# ── 0. Stable signing identity (required so TCC persistence is what we're testing) ────────────
# Capture-then-grep (not `… | grep -qF`): pipefail + grep's early-exit SIGPIPE can otherwise turn a
# present identity into a false miss and needlessly re-run setup.
IDENT_LIST="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if ! grep -qF "$IDENTITY" <<<"$IDENT_LIST"; then
    echo "==> Stable signing identity '$IDENTITY' not found — creating it (one password prompt)..."
    bash scripts/setup-signing-cert.sh
fi

# ── 1. Build the release once ─────────────────────────────────────────────────
echo "==> Building release from current worktree..."
bash package_app.sh --release
# Confirm it actually got the stable identity (else the TCC-persistence half of the test is void).
# Check the signing Authority, not the designated requirement: the DR pins the cert by hash
# (certificate leaf = H"…"), so the identity NAME appears in `codesign -dvv` (Authority=…), not in
# `codesign -d -r-`. Grepping the DR for the name always fails even on a correctly-signed bundle.
# Capture first, then grep: piping verbose `codesign -dvv` straight into `grep -q` makes grep close
# the pipe on first match, codesign takes SIGPIPE (exit 141), and `set -o pipefail` turns that into
# a false failure. Reading into a variable side-steps the broken pipe entirely.
SIGN_INFO="$(codesign -dvv dist/Parley.app 2>&1 || true)"
if ! grep -q "Authority=$IDENTITY" <<<"$SIGN_INFO"; then
    echo "error: dist/Parley.app is not signed with '$IDENTITY' — the update would still drop TCC."
    echo "       Run scripts/setup-signing-cert.sh and retry."
    exit 1
fi
BUILD_TS="$(git show -s --format=%ct HEAD)"

# ── 2. Stage OLD (0.7.0) and NEW (0.7.1) from the one build ───────────────────
echo "==> Staging OLD (0.7.0) and NEW (0.7.1)..."
rm -rf "$DRYRUN_DIR"
mkdir -p "$UPDATES_DIR" "$STAGE_DIR"

OLD_APP="$STAGE_DIR/old/Parley.app"
NEW_APP="$STAGE_DIR/new/Parley.app"
mkdir -p "$STAGE_DIR/old" "$STAGE_DIR/new"
cp -a dist/Parley.app "$OLD_APP"
cp -a dist/Parley.app "$NEW_APP"

# NEW: 0.7.1, build = HEAD timestamp (higher than OLD's).
plutil -replace CFBundleShortVersionString -string "0.7.1"        "$NEW_APP/Contents/Info.plist"
plutil -replace CFBundleVersion            -string "$BUILD_TS"    "$NEW_APP/Contents/Info.plist"

# OLD: 0.7.0, build = timestamp - 100000 (strictly lower so Sparkle sees NEW as an upgrade), and
# its feed repointed at our localhost appcast with an ATS exception so the http load is allowed.
plutil -replace CFBundleShortVersionString -string "0.7.0"                 "$OLD_APP/Contents/Info.plist"
plutil -replace CFBundleVersion            -string "$((BUILD_TS - 100000))" "$OLD_APP/Contents/Info.plist"
plutil -replace SUFeedURL                  -string "$FEED_URL"             "$OLD_APP/Contents/Info.plist"
plutil -replace NSAppTransportSecurity -json '{"NSExceptionDomains":{"localhost":{"NSExceptionAllowsInsecureHTTPLoads":true}}}' "$OLD_APP/Contents/Info.plist"

# plutil edits break the code seal — re-sign both bundles (deep, innermost handled by --force here
# since the framework/XPC seals are unchanged; the app seal must be regenerated).
codesign --force --sign "$IDENTITY" "$OLD_APP"
codesign --force --sign "$IDENTITY" "$NEW_APP"
codesign --verify --deep --strict "$OLD_APP"
codesign --verify --deep --strict "$NEW_APP"

# ── 3. Archive NEW and generate the signed appcast pointing at localhost ──────
echo "==> Archiving NEW and generating signed appcast..."
ditto -c -k --sequesterRsrc --keepParent "$NEW_APP" "$UPDATES_DIR/Parley-0.7.1.zip"
# generate_appcast signs the zip with the Sparkle EdDSA key in the login Keychain (the same key
# whose public half is the embedded SUPublicEDKey) — it may prompt for keychain access once.
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "http://localhost:$PORT/" "$UPDATES_DIR"

# ── 4. Install OLD and start the local feed server ────────────────────────────
echo "==> Installing OLD (0.7.0) to /Applications (clobbers any existing Parley.app)..."
rm -rf "/Applications/Parley.app"
cp -a "$OLD_APP" "/Applications/Parley.app"

# Clean TCC once so the OLD install starts from a known state; you grant fresh on first launch,
# then we check the grants SURVIVE the update. (This is the one-time reset the migration needs.)
for svc in Microphone ScreenCapture Calendar SystemPolicyDocumentsFolder; do
    tccutil reset "$svc" eu.fmasi.parley >/dev/null 2>&1 || true
done

echo "==> Starting local feed server on http://localhost:$PORT ..."
( cd "$UPDATES_DIR" && exec python3 -m http.server "$PORT" >/dev/null 2>&1 ) &
echo $! > "$PIDFILE"
sleep 1
if ! curl -fsS "$FEED_URL" -o /dev/null; then
    echo "error: local feed not reachable at $FEED_URL"; exit 1
fi

# ── 5. Print the single manual test ───────────────────────────────────────────
cat <<EOF

────────────────────────────────────────────────────────────────────────────
✓ Ready. Local appcast is live at $FEED_URL
  OLD (0.7.0) is installed at /Applications/Parley.app; NEW (0.7.1) is the update.

RUN THE SINGLE TEST — in order:

  1. Launch:            open /Applications/Parley.app
     • Grant Microphone + Screen Recording when prompted (this is OLD 0.7.0).
     • Confirm exactly ONE menu-bar icon (single-instance guard, #109).

  2. Update:            menu bar → Parley → "Check for Updates…"
     • Expect an update dialog offering 0.7.1. Click Install & Relaunch.
     • Sparkle downloads over localhost, verifies the EdDSA signature, installs,
       and relaunches. (This is the download→verify→install path #114.3.)

  3. Verify the update:
     • Settings/About now reports 0.7.1.
     • ★ You were NOT re-prompted for Microphone/Screen Recording — TCC survived
       the update (the whole point of stable signing). If it re-prompted, note it.
     • Still exactly ONE menu-bar icon (#109).

  4. Exercise the shipping build (now running as 0.7.1):
     • Record a short 3-speaker clip; switch output (speakers ↔ AirPods) mid-record
       → audio stays clean, no chipmunk/speed-up (tap hardening #111/#112).
     • Open the transcript: speakers read "Speaker 1/2/3", never "spk_N" (#113).

WHEN DONE:            bash scripts/sparkle-dryrun.sh --stop
────────────────────────────────────────────────────────────────────────────

TROUBLESHOOTING
  • No update offered → Sparkle caches feed results; wait a few seconds and retry
    "Check for Updates…", or quit/relaunch OLD first. Confirm the feed is up:
        curl -s $FEED_URL | grep sparkle:version
  • "Update is improperly signed" → the codesign identity or the EdDSA key differs
    between OLD and NEW; both must be '$IDENTITY' + the same Sparkle key. Re-run this
    script after scripts/setup-signing-cert.sh.
EOF
