#!/usr/bin/env bash
# scripts/setup-signing-cert.sh — create a STABLE self-signed code-signing identity for Parley.
#
# WHY THIS EXISTS
#   Parley ships outside the App Store and auto-updates via Sparkle. macOS binds each TCC
#   permission grant (Microphone, Screen Recording, Calendar, …) to the app's *designated
#   requirement*, which is derived from its code signature. Ad-hoc signing (`codesign --sign -`)
#   mints a fresh cdhash on every build with no stable identity to pin to, so macOS treats every
#   update as a brand-new app and DROPS all permission grants — the user then has to remove and
#   re-add Parley in System Settings for each permission after every update.
#
#   A stable signing identity fixes the designated requirement to a constant certificate
#   (`identifier "eu.fmasi.parley" and certificate leaf H"…"`). Because that requirement is
#   identical across rebuilds, TCC re-matches the updated build and KEEPS the grants. This is the
#   free equivalent of what a Developer ID cert does; see docs/gotchas.md for the upgrade path
#   (Developer ID also unlocks notarization + `.critical` alerts).
#
# WHAT YOU'LL SEE
#   One macOS password prompt — to trust the new certificate for code signing. That's the only
#   interactive step; every build afterwards signs non-interactively.
#
# IDEMPOTENT: re-running once the identity is present and valid is a no-op.

set -euo pipefail

IDENTITY="Parley Self-Signed"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

# Capture-then-grep, never `… | grep -qF`: under `set -o pipefail`, grep exits on first match and
# closes the pipe, security takes SIGPIPE (141), and pipefail reports the pipeline as failed — a
# false negative that would make this "already present" check re-create the cert every run.
if grep -qF "$IDENTITY" <<<"$(security find-identity -v -p codesigning 2>/dev/null || true)"; then
    echo "✓ '$IDENTITY' already present and valid — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Generating self-signed code-signing certificate ('$IDENTITY')..."
# Use the SYSTEM LibreSSL (/usr/bin/openssl), not a Homebrew/conda OpenSSL 3.x: OpenSSL 3.x writes
# a PKCS12 whose MAC Apple's Security framework can't verify ("MAC verification failed"), so the
# import silently produces no identity. LibreSSL's default PKCS12 is `security`-importable.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
    -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass:parley -name "$IDENTITY" 2>/dev/null

echo "==> Importing into your login keychain..."
# -A lets codesign use the private key without a per-signing access prompt.
security import "$TMP/cert.p12" -k "$LOGIN_KC" -P parley -A

echo "==> Trusting the certificate for code signing..."
echo "    (a macOS password prompt will appear — enter your login password to approve)"
# A self-signed cert is reported CSSMERR_TP_NOT_TRUSTED and codesign refuses it until it's trusted.
# Trust it as a root for the code-signing policy in the USER domain (no sudo, no system-wide change).
security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KC" "$TMP/cert.pem"

echo
if grep -qF "$IDENTITY" <<<"$(security find-identity -v -p codesigning 2>/dev/null || true)"; then
    echo "✓ Done. '$IDENTITY' is ready."
    echo "  package_app.sh now signs with it automatically (falls back to ad-hoc if it's ever removed)."
    echo
    echo "  NOTE: the first build after switching from ad-hoc signing changes the app's identity once,"
    echo "  so that ONE update/build still needs permissions re-granted. Every build after that keeps them."
else
    echo "! Imported but not yet showing as valid. Open Keychain Access → find '$IDENTITY' →"
    echo "  expand Trust → set 'Code Signing: Always Trust', then re-run this script to confirm."
    exit 1
fi
