#!/bin/bash
# Integration test for scripts/verify-release-feed.sh against a localhost fixture appcast.
#
# Generates an ephemeral Ed25519 keypair (CryptoKit == Sparkle's EdDSA scheme), signs a fixture
# "zip", serves it over localhost, and asserts the verifier PASSES a valid feed and REJECTS a
# tampered one. Cross-compatibility with Sparkle's real sign_update is covered by
# scripts/sparkle-dryrun.sh and the first real release, not here.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product verify-ed-signature >/dev/null 2>&1 || { echo "FAIL: could not build verify-ed-signature"; exit 1; }
VBIN="$(swift build --product verify-ed-signature --show-bin-path 2>/dev/null)/verify-ed-signature"

TMP="$(mktemp -d)"
SRV=0
cleanup() { [[ "$SRV" != 0 ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

FEED="$TMP/feed"; mkdir -p "$FEED"
head -c 4096 /dev/urandom > "$FEED/Parley-0.9.0.zip"

# Ephemeral keypair + signature over the fixture bytes.
cat > "$TMP/sign.swift" <<'SWIFT'
import CryptoKit
import Foundation
let data = FileManager.default.contents(atPath: CommandLine.arguments[1])!
let key = Curve25519.Signing.PrivateKey()
let sig = try! key.signature(for: data)
print(key.publicKey.rawRepresentation.base64EncodedString())
print(sig.base64EncodedString())
SWIFT
swiftc "$TMP/sign.swift" -o "$TMP/sign" || { echo "FAIL: could not compile the fixture signer"; exit 1; }
OUT="$("$TMP/sign" "$FEED/Parley-0.9.0.zip")"
PUBKEY="$(printf '%s\n' "$OUT" | sed -n 1p)"
SIG="$(printf '%s\n' "$OUT" | sed -n 2p)"
LEN="$(wc -c < "$FEED/Parley-0.9.0.zip" | tr -d ' ')"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')"
cat > "$FEED/appcast.xml" <<XML
<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><sparkle:shortVersionString>0.9.0</sparkle:shortVersionString>
<enclosure url="http://localhost:$PORT/Parley-0.9.0.zip" sparkle:edSignature="$SIG" length="$LEN"/>
</item></channel></rss>
XML

python3 -m http.server "$PORT" --directory "$FEED" >/dev/null 2>&1 &
SRV=$!
disown "$SRV" 2>/dev/null || true   # silence the job-control "Terminated" notice on cleanup
ready=0
for _ in $(seq 1 50); do
    curl -fsS "http://localhost:$PORT/appcast.xml" -o /dev/null 2>/dev/null && { ready=1; break; }
    sleep 0.1   # curl fails instantly when nothing's listening; space out so the poll can wait ~5s
done
[[ "$ready" == 1 ]] || { echo "FAIL: fixture server did not come up"; exit 1; }

# Valid feed -> pass.
if VERIFY_ED_SIGNATURE_BIN="$VBIN" bash scripts/verify-release-feed.sh 0.9.0 \
        --feed-url "http://localhost:$PORT/appcast.xml" --pubkey "$PUBKEY" >/dev/null; then
    echo "  valid feed: PASS"
else
    echo "FAIL: valid feed was rejected"; exit 1
fi

# Tamper the served bytes so the signature no longer matches -> must fail.
head -c 4096 /dev/urandom > "$FEED/Parley-0.9.0.zip"
if VERIFY_ED_SIGNATURE_BIN="$VBIN" bash scripts/verify-release-feed.sh 0.9.0 \
        --feed-url "http://localhost:$PORT/appcast.xml" --pubkey "$PUBKEY" >/dev/null 2>&1; then
    echo "FAIL: tampered feed was accepted"; exit 1
else
    echo "  tampered feed: correctly rejected"
fi

echo "PASS"
