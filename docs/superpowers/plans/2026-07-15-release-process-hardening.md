# Release-process hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn every silent post-publish release failure (broken feed, wrong "latest", blank/drifted notes, unverified signatures) into a loud, automatic failure, and script the manual publish step.

**Architecture:** Five small units on `feature/release-hardening` (off `main`): a Python stdlib md→HTML notes renderer, a CryptoKit Ed25519 signature-verify executable, a `verify-release-feed.sh` that checks the *published* feed end-to-end, a guarded `publish.sh`, and a CI+cron workflow that runs the verifier. Plus wiring into `release.sh` and a rewritten checklist.

**Tech Stack:** bash 3.2, Python 3 stdlib, Swift + CryptoKit (SwiftPM executable target), GitHub Actions, `gh` CLI, Sparkle `generate_appcast`.

## Global Constraints

- Platform: macOS 15+ / Apple Silicon. CI runs `macos-15`.
- Release tooling stays dependency-light: **no pip installs**; Python 3 **stdlib only**.
- Signature verification is **public-key-only** — no secret in CI; `SUPublicEDKey` read from `packaging/Info.plist`.
- Ed25519 (RFC 8032) is the signature scheme (Sparkle EdDSA == CryptoKit `Curve25519.Signing`).
- Every guard **fails closed**: specific message + non-zero exit, matching `scripts/release.sh` style.
- Swift test invocation uses the documented CommandLineTools framework flags (see `CLAUDE.md`).
- Repo: `fmasi/parley`. Feed URL: `https://github.com/fmasi/parley/releases/latest/download/appcast.xml`.
- Bash scripts: stock macOS bash 3.2 — no `mapfile`, no `${arr[@]}` on possibly-empty arrays.

---

### Task 1: Markdown→HTML release-notes renderer

**Files:**
- Create: `scripts/render-release-notes.py`
- Test: `scripts/test_render_release_notes.py`

**Interfaces:**
- Produces: CLI `python3 scripts/render-release-notes.py <input.md> <output.html>`; writes HTML, exits 0 on success, non-zero + stderr message on missing/empty input.
- Produces (importable): `render_markdown(md: str) -> str` returning an HTML fragment (no `<html>`/`<body>` wrapper — Sparkle injects into its notes pane).
- Supported subset: ATX headings `#`..`######`; paragraphs; unordered lists (`- ` / `* `); ordered lists (`1. `); fenced code blocks ```` ``` ````; inline `**bold**`, `*italic*`, `` `code` ``, `[text](url)`. All text HTML-escaped; `&`, `<`, `>`, `"` escaped in text and URLs.

- [ ] **Step 1: Write failing tests** (`scripts/test_render_release_notes.py`) — these test cases ARE the renderer spec:

```python
import subprocess, sys, os, tempfile, unittest
sys.path.insert(0, os.path.dirname(__file__))
from render_release_notes import render_markdown

class RenderMarkdownTests(unittest.TestCase):
    def test_heading_levels(self):
        self.assertEqual(render_markdown("# Title"), "<h1>Title</h1>")
        self.assertEqual(render_markdown("### Sub"), "<h3>Sub</h3>")

    def test_paragraph_and_inline(self):
        self.assertEqual(
            render_markdown("Fixed **crash** in `run()` see [#135](https://x/135)."),
            '<p>Fixed <strong>crash</strong> in <code>run()</code> '
            'see <a href="https://x/135">#135</a>.</p>')

    def test_italic(self):
        self.assertEqual(render_markdown("*measured*, not guessed"),
                         "<p><em>measured</em>, not guessed</p>")

    def test_unordered_list(self):
        self.assertEqual(render_markdown("- one\n- two"),
                         "<ul>\n<li>one</li>\n<li>two</li>\n</ul>")

    def test_ordered_list(self):
        self.assertEqual(render_markdown("1. first\n2. second"),
                         "<ol>\n<li>first</li>\n<li>second</li>\n</ol>")

    def test_fenced_code_is_escaped_verbatim(self):
        self.assertEqual(render_markdown("```\na < b && c\n```"),
                         "<pre><code>a &lt; b &amp;&amp; c\n</code></pre>")

    def test_html_escaping_in_text(self):
        self.assertEqual(render_markdown("a < b & \"c\""),
                         '<p>a &lt; b &amp; &quot;c&quot;</p>')

    def test_blank_lines_separate_paragraphs(self):
        self.assertEqual(render_markdown("one\n\ntwo"),
                         "<p>one</p>\n<p>two</p>")

    def test_cli_rejects_empty_file(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "e.md"); open(src, "w").close()
            out = os.path.join(d, "e.html")
            r = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__),
                                "render-release-notes.py"), src, out],
                               capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("empty", r.stderr.lower())

if __name__ == "__main__":
    unittest.main()
```

Note: the CLI test imports the module as `render_release_notes` but the file is `render-release-notes.py` (hyphen). Provide an import shim: the test adds a `render_release_notes.py` that `from render-release-notes` can't do — so instead name the importable module `render_release_notes.py` and make `render-release-notes.py` a thin `argv` wrapper that imports it. **Adjust:** create BOTH `scripts/render_release_notes.py` (module with `render_markdown` + `main`) and keep the CLI entry as `scripts/render-release-notes.py` importing it. Update the CLI test path accordingly.

- [ ] **Step 2: Run tests, verify they fail**

Run: `python3 scripts/test_render_release_notes.py -v`
Expected: FAIL (module not found).

- [ ] **Step 3: Implement `scripts/render_release_notes.py`**

Block-level line scanner (fenced-code state first, then headings, lists, blank-line-separated paragraphs), with an inline pass applied to non-code text in this order: escape HTML → inline code (protect from further parsing) → links → bold → italic. Implement `render_markdown(md)` returning joined blocks, and `main(argv)` that reads input (error+exit 2 if missing/empty after strip), writes output. Full implementation written during TDD to satisfy every case above; keep inline replacement regex-based over already-escaped text, restoring `` `code` `` spans last.

- [ ] **Step 4: Run tests, verify pass**

Run: `python3 scripts/test_render_release_notes.py -v`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/render_release_notes.py scripts/render-release-notes.py scripts/test_render_release_notes.py
git commit -m "feat(release): single-source md->html release-notes renderer"
```

---

### Task 2: CryptoKit Ed25519 signature-verify executable

**Files:**
- Modify: `Package.swift` (add executable target `verify-ed-signature`)
- Create: `Tools/VerifyEdSignature/main.swift`
- Test: `SwiftTests/TranscriberTests/EdSignatureVerifyTests.swift`

**Interfaces:**
- Produces: executable `verify-ed-signature --pubkey <base64> --signature <base64> --file <path>`; exits 0 if the Ed25519 signature is valid for the file bytes under the public key, 1 if invalid, 2 on usage/IO error. base64 inputs are the Sparkle formats (`SUPublicEDKey` = 32-byte key; `sparkle:edSignature` = 64-byte sig).
- Produces (testable): `func verifyEd25519(pubKeyBase64: String, signatureBase64: String, fileData: Data) -> Bool` in a tiny library so tests don't shell out.

- [ ] **Step 1: Write failing test** (`EdSignatureVerifyTests.swift`)

```swift
import Testing
import Foundation
import CryptoKit
@testable import VerifyEdSignatureCore

@Suite struct EdSignatureVerifyTests {
    @Test func validSignatureVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let msg = Data("release bytes".utf8)
        let sig = try key.signature(for: msg)
        #expect(verifyEd25519(
            pubKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
            signatureBase64: sig.base64EncodedString(),
            fileData: msg) == true)
    }
    @Test func tamperedFileFails() throws {
        let key = Curve25519.Signing.PrivateKey()
        let sig = try key.signature(for: Data("original".utf8))
        #expect(verifyEd25519(
            pubKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
            signatureBase64: sig.base64EncodedString(),
            fileData: Data("tampered".utf8)) == false)
    }
    @Test func garbageInputsFailClosed() {
        #expect(verifyEd25519(pubKeyBase64: "!!!", signatureBase64: "!!!",
                              fileData: Data()) == false)
    }
}
```

- [ ] **Step 2: Add the target to `Package.swift`**

Add a library target `VerifyEdSignatureCore` (with `func verifyEd25519(...)`), an executable target `verify-ed-signature` depending on it, and add `VerifyEdSignatureCore` to the test target's dependencies. Mirror the existing target style in `Package.swift`.

- [ ] **Step 3: Run test, verify it fails**

Run: `swift test --filter EdSignatureVerifyTests <framework flags>`
Expected: FAIL (no such module / symbol).

- [ ] **Step 4: Implement core + executable**

`VerifyEdSignatureCore` (`Sources/VerifyEdSignatureCore/Verify.swift`):
```swift
import Foundation
import CryptoKit
public func verifyEd25519(pubKeyBase64: String, signatureBase64: String, fileData: Data) -> Bool {
    guard let pub = Data(base64Encoded: pubKeyBase64),
          let sig = Data(base64Encoded: signatureBase64),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub)
    else { return false }
    return key.isValidSignature(sig, for: fileData)
}
```
`Tools/VerifyEdSignature/main.swift`: parse `--pubkey/--signature/--file`, read file (exit 2 on IO/usage error), call `verifyEd25519`, `exit(result ? 0 : 1)`.

- [ ] **Step 5: Run test + build the exe, verify pass**

Run: `swift test --filter EdSignatureVerifyTests <framework flags>` → PASS (3 tests).
Run: `swift build --product verify-ed-signature` → builds.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/VerifyEdSignatureCore Tools/VerifyEdSignature SwiftTests/TranscriberTests/EdSignatureVerifyTests.swift
git commit -m "feat(release): CryptoKit Ed25519 verify executable (public-key-only)"
```

---

### Task 3: `verify-release-feed.sh` — published-feed integrity verifier

**Files:**
- Create: `scripts/verify-release-feed.sh`
- Create: `scripts/appcast_lib.py` (pure, testable XML/version logic)
- Test: `scripts/test_appcast_lib.py`
- Test: `scripts/test-verify-release-feed.sh` (integration vs. localhost fixture)
- Fixture: `scripts/fixtures/feed/` (appcast.xml + a zip, ephemeral-key-signed at test time)

**Interfaces:**
- Consumes: `verify-ed-signature` (Task 2) for signature checks; `SUPublicEDKey` from `packaging/Info.plist`.
- Produces: CLI `bash scripts/verify-release-feed.sh [<version>] [--feed-url <url>] [--pubkey <b64>]`. Defaults `<version>` to the newest published release (`gh release view --json tagName`), `--feed-url` to the real feed, `--pubkey` to the plist value. Exit 0 = all invariants hold; non-zero + first-violation message otherwise.
- Produces (`appcast_lib.py`): `newest_item(appcast_xml: str) -> dict` (keys: `version`, `url`, `ed_signature`); `all_enclosure_urls(appcast_xml: str) -> list[str]`; `version_from_filename(name: str) -> str`. Pure string→data, no network.

- [ ] **Step 1: Write failing pure-logic tests** (`scripts/test_appcast_lib.py`)

```python
import sys, os, unittest
sys.path.insert(0, os.path.dirname(__file__))
from appcast_lib import newest_item, all_enclosure_urls, version_from_filename

APPCAST = '''<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><sparkle:shortVersionString>0.9.0</sparkle:shortVersionString>
<enclosure url="https://github.com/fmasi/parley/releases/download/v0.9.0/Parley-0.9.0.zip"
 sparkle:edSignature="SIG090" length="1"/></item>
<item><sparkle:shortVersionString>0.8.2</sparkle:shortVersionString>
<enclosure url="https://github.com/fmasi/parley/releases/download/v0.8.2/Parley-0.8.2.zip"
 sparkle:edSignature="SIG082" length="1"/></item>
</channel></rss>'''

class AppcastLibTests(unittest.TestCase):
    def test_newest_item(self):
        it = newest_item(APPCAST)
        self.assertEqual(it["version"], "0.9.0")
        self.assertTrue(it["url"].endswith("/v0.9.0/Parley-0.9.0.zip"))
        self.assertEqual(it["ed_signature"], "SIG090")
    def test_all_urls(self):
        self.assertEqual(len(all_enclosure_urls(APPCAST)), 2)
    def test_version_from_filename(self):
        self.assertEqual(version_from_filename("Parley-0.9.0.zip"), "0.9.0")

if __name__ == "__main__":
    unittest.main()
```

"Newest" = highest by semver tuple (not document order) — `test_newest_item` must pass even if 0.8.2 were listed first; add such a reordered case.

- [ ] **Step 2: Run, verify fail.** `python3 scripts/test_appcast_lib.py -v` → FAIL.

- [ ] **Step 3: Implement `scripts/appcast_lib.py`** — `xml.etree.ElementTree` parse with the sparkle namespace; semver-tuple max for `newest_item`; regex `Parley-(\d+\.\d+\.\d+)\.zip` for `version_from_filename`.

- [ ] **Step 4: Run, verify pass.** `python3 scripts/test_appcast_lib.py -v` → PASS.

- [ ] **Step 5: Implement `scripts/verify-release-feed.sh`** — the invariants, each failing closed with a named value:
  1. `curl -fsSL <feed-url>` returns 0 and body parses (`appcast_lib`);
  2. `curl -sI https://github.com/fmasi/parley/releases/latest` `location:` resolves to `/tag/v<version>`;
  3. `newest_item.version == <version>`;
  4. each `all_enclosure_urls` returns HTTP 200 (`curl -fsIL -o /dev/null -w '%{http_code}'`);
  5. download the newest enclosure zip to a temp file, run `verify-ed-signature --pubkey <plist> --signature <newest.ed_signature> --file <zip>` → exit 0.
  Read `SUPublicEDKey` via `plutil -extract SUPublicEDKey raw packaging/Info.plist`.

- [ ] **Step 6: Write integration test** (`scripts/test-verify-release-feed.sh`) — generate an ephemeral CryptoKit keypair + sign a fixture zip (via a `--selftest-sign` mode of the `verify-ed-signature` tool, or a 6-line swift snippet), write a fixture `appcast.xml` referencing `http://localhost:$PORT/...`, serve `scripts/fixtures/feed/` with `python3 -m http.server`, and run `verify-release-feed.sh 0.9.0 --feed-url http://localhost:$PORT/appcast.xml --pubkey <ephemeral>`. Assert exit 0; then flip one signature byte and assert non-zero. (Cross-compat with Sparkle's real signer is covered by `sparkle-dryrun.sh` + the first real release; note this in a comment.)

- [ ] **Step 7: Run integration test, verify pass.** `bash scripts/test-verify-release-feed.sh` → prints PASS, exit 0.

- [ ] **Step 8: Commit**

```bash
git add scripts/verify-release-feed.sh scripts/appcast_lib.py scripts/test_appcast_lib.py scripts/test-verify-release-feed.sh scripts/fixtures/feed
git commit -m "feat(release): published-feed integrity verifier (#119)"
```

---

### Task 4: `publish.sh` — guarded release publish

**Files:**
- Create: `scripts/publish.sh`
- Test: `scripts/test-publish.sh`

**Interfaces:**
- Consumes: `verify-release-feed.sh` (Task 3).
- Produces: CLI `bash scripts/publish.sh <version> [--line current|stable] [--dry-run]`. Default `--line current`. `--dry-run` prints the `gh release create` command it *would* run (and skips the post-publish verify) instead of executing.
- Rule: `--line current` → `--latest=true`; `--line stable` → `--latest=false`.

- [ ] **Step 1: Write failing test** (`scripts/test-publish.sh`) — dry-run flag assertions:

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Preconditions the script needs present; create throwaway stand-ins.
tmp=$(mktemp -d); mkdir -p "$tmp/release/updates" "$tmp/release/release-notes"
echo zip > "$tmp/release/Parley-0.9.0.zip"
echo '<rss/>' > "$tmp/release/updates/appcast.xml"
echo 'notes' > "$tmp/release/release-notes/0.9.0.md"
out=$(RELEASE_ROOT="$tmp" SKIP_GIT_PRECHECKS=1 bash scripts/publish.sh 0.9.0 --line current --dry-run)
grep -q -- '--latest=true' <<<"$out" || { echo "FAIL: current not --latest=true"; exit 1; }
out=$(RELEASE_ROOT="$tmp" SKIP_GIT_PRECHECKS=1 bash scripts/publish.sh 0.9.0 --line stable --dry-run)
grep -q -- '--latest=false' <<<"$out" || { echo "FAIL: stable not --latest=false"; exit 1; }
grep -q 'release/release-notes/0.9.0.md' <<<"$out" || { echo "FAIL: notes-file missing"; exit 1; }
echo "PASS"
```

(`RELEASE_ROOT` and `SKIP_GIT_PRECHECKS` are test seams the script must honor: default `RELEASE_ROOT=.`, and skip tag/HEAD/clean-tree checks only when `SKIP_GIT_PRECHECKS=1`.)

- [ ] **Step 2: Run, verify fail.** `bash scripts/test-publish.sh` → FAIL (script missing).

- [ ] **Step 3: Implement `scripts/publish.sh`** — parse args; unless `SKIP_GIT_PRECHECKS=1`, assert tag exists / HEAD on tag / clean tree (reuse `release.sh`'s checks); assert `$RELEASE_ROOT/release/Parley-<v>.zip`, `.../updates/appcast.xml`, `.../release-notes/<v>.md` exist and non-empty; build the safe deltas array; compose the `gh release create` command with explicit `--latest=<bool>` and `--notes-file <.../release-notes/<v>.md>`; on `--dry-run` echo it, else run it then `verify-release-feed.sh <v>`.

- [ ] **Step 4: Run, verify pass.** `bash scripts/test-publish.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/publish.sh scripts/test-publish.sh
git commit -m "feat(release): guarded publish.sh with explicit --latest and post-publish verify"
```

---

### Task 5: CI post-publish + cron feed guard

**Files:**
- Create: `.github/workflows/release-feed.yml`

**Interfaces:**
- Consumes: `verify-release-feed.sh` (Task 3), `verify-ed-signature` (Task 2).

- [ ] **Step 1: Write the workflow**

```yaml
name: Release feed integrity
on:
  release:
    types: [published, edited]
  schedule:
    - cron: "17 7 * * *"   # daily — catches a release later drafted/deleted reverting "latest"
  workflow_dispatch:
permissions:
  contents: read
  issues: write            # to open a tracking issue on failure
jobs:
  verify-feed:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Build the signature verifier
        run: swift build --product verify-ed-signature
      - name: Verify the published feed
        env:
          GH_TOKEN: ${{ github.token }}
        run: bash scripts/verify-release-feed.sh
      - name: Open an issue if the feed is broken
        if: failure()
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh issue create --title "Sparkle feed integrity FAILED ($(date -u +%F))" \
            --body "release-feed.yml failed — the auto-update feed may be broken. See the run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}" \
            --label release || true
```

- [ ] **Step 2: Lint the YAML.** Run `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release-feed.yml'))"` (PyYAML may be absent → fall back to `actionlint` if installed, else visual check). Expected: parses.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release-feed.yml
git commit -m "ci(release): post-publish + daily feed-integrity guard (#119)"
```

---

### Task 6: Wire renderer into `release.sh`; rewrite the checklist

**Files:**
- Modify: `scripts/release.sh` (call the renderer before `generate_appcast`)
- Modify: `docs/release-checklist.md`

**Interfaces:**
- Consumes: `render-release-notes.py` (Task 1).

- [ ] **Step 1: Modify `release.sh`** — before the `generate_appcast` call, if `release/release-notes/<version>.md` exists, run `python3 scripts/render-release-notes.py release/release-notes/<version>.md "$UPDATES_DIR/Parley-<version>.html"`; keep the existing "warning if no HTML" as a fallback for notes-less releases. This makes the HTML a *product* of the md, never hand-authored.

- [ ] **Step 2: Manual smoke** — with a sample `release/release-notes/0.9.0.md`, run just the render line and confirm `Parley-0.9.0.html` is produced and non-empty. (Full `release.sh` needs a tag/build; not run here.)

- [ ] **Step 3: Rewrite `docs/release-checklist.md`** — collapse to: (1) write `release/release-notes/<v>.md`; (2) tag; (3) `bash scripts/release.sh <v>` (now renders HTML too); (4) `bash scripts/publish.sh <v> [--line current|stable]` (guarded, auto-verifies); (5) CI + daily cron watch the feed. Add the explicit branch-model paragraph: `main` = 0.9.x dev / live Sparkle line; `release/0.8.x` = frozen stable, critical backports only, published `--line stable` (never latest).

- [ ] **Step 4: Commit**

```bash
git add scripts/release.sh docs/release-checklist.md
git commit -m "feat(release): render notes in release.sh; rewrite checklist for guarded flow"
```

---

## Self-Review

**Spec coverage:** §1 notes renderer → Task 1 + Task 6 wiring. §2 verifier → Task 3 (+ Task 2 signature dep). §3 publish.sh → Task 4. §4 CI guard → Task 5. §5 two-line protection → Task 4 (`--line` → explicit `--latest`) + Task 3 (invariant 2/3) + Task 6 (docs). Testing table → tests in every task. All spec sections mapped.

**Type consistency:** `verifyEd25519(pubKeyBase64:signatureBase64:fileData:)` used identically in Task 2 test + impl. `verify-ed-signature --pubkey/--signature/--file` consistent across Tasks 2/3. `newest_item`/`all_enclosure_urls`/`version_from_filename` consistent across Task 3 test + impl + `verify-release-feed.sh`. `publish.sh <version> --line current|stable --dry-run` + `RELEASE_ROOT`/`SKIP_GIT_PRECHECKS` seams consistent Task 4 test + impl.

**Placeholders:** renderer/impl bodies (Task 1 step 3, Task 3 step 3) are specified by their exhaustive test cases rather than repeated line-for-line — acceptable because the tests fully pin behavior; all other steps carry literal code.

## Notes for the executor
- The renderer module naming (hyphen CLI vs underscore importable) is resolved in Task 1 step 1's note: ship `render_release_notes.py` (module) + `render-release-notes.py` (thin CLI wrapper).
- Run `swift build` once before Task 3's integration test so `verify-ed-signature` exists.
- This PR ships **no product-code change**; device test = run `scripts/sparkle-dryrun.sh` once + confirm the render + publish `--dry-run`.
