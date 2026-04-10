# Version Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add software version traceability to transcript JSON metadata (#42) and a native About panel (#33).

**Architecture:** Build-time injection of git-derived version info into Info.plist via `package_app.sh`. Runtime `AppVersion` enum reads from `Bundle.main.infoDictionary`. TranscriptAssembler embeds `software_version` in metadata. MenuView gains an About menu item.

**Tech Stack:** Swift, plutil, git describe, Swift Testing

---

### Task 1: AppVersion — runtime version reader

**Files:**
- Create: `TranscriberCore/AppVersion.swift`
- Create: `SwiftTests/TranscriberTests/AppVersionTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `SwiftTests/TranscriberTests/AppVersionTests.swift`:

```swift
import Testing
import Foundation
@testable import TranscriberCore

struct AppVersionTests {

    // -- parseCommitHash --

    @Test func parseCommitHashFromFullDescribe() {
        // "v0.6.1-12-ga3f9c12" -> "a3f9c12"
        let hash = AppVersion.parseCommitHash(from: "v0.6.1-12-ga3f9c12")
        #expect(hash == "a3f9c12")
    }

    @Test func parseCommitHashFromDirtyDescribe() {
        let hash = AppVersion.parseCommitHash(from: "v0.6.1-3-gabcdef0-dirty")
        #expect(hash == "abcdef0")
    }

    @Test func parseCommitHashFromTagOnly() {
        // Exactly on a tag: "v0.7.0" -> nil (no commit hash in string)
        let hash = AppVersion.parseCommitHash(from: "v0.7.0")
        #expect(hash == nil)
    }

    @Test func parseCommitHashFromHashOnly() {
        // No tags: "a3f9c12" -> "a3f9c12"
        let hash = AppVersion.parseCommitHash(from: "a3f9c12")
        #expect(hash == "a3f9c12")
    }

    @Test func parseCommitHashFromHashOnlyDirty() {
        let hash = AppVersion.parseCommitHash(from: "a3f9c12-dirty")
        #expect(hash == "a3f9c12")
    }

    // -- parseCommitDistance --

    @Test func parseCommitDistanceFromFullDescribe() {
        let distance = AppVersion.parseCommitDistance(from: "v0.6.1-12-ga3f9c12")
        #expect(distance == 12)
    }

    @Test func parseCommitDistanceFromTagOnly() {
        let distance = AppVersion.parseCommitDistance(from: "v0.7.0")
        #expect(distance == 0)
    }

    @Test func parseCommitDistanceFromHashOnly() {
        let distance = AppVersion.parseCommitDistance(from: "a3f9c12")
        #expect(distance == nil)
    }

    // -- displayString --

    @Test func displayStringWithHashAndVersion() {
        let display = AppVersion.formatDisplay(version: "0.6.1", gitDescription: "v0.6.1-12-ga3f9c12")
        #expect(display == "0.6.1 (a3f9c12)")
    }

    @Test func displayStringOnTag() {
        let display = AppVersion.formatDisplay(version: "0.7.0", gitDescription: "v0.7.0")
        #expect(display == "0.7.0")
    }

    @Test func displayStringDirty() {
        let display = AppVersion.formatDisplay(version: "0.6.1", gitDescription: "v0.6.1-3-gabcdef0-dirty")
        #expect(display == "0.6.1 (abcdef0-dirty)")
    }

    @Test func displayStringDevFallback() {
        let display = AppVersion.formatDisplay(version: "dev", gitDescription: "unknown")
        #expect(display == "dev")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
swift test --filter AppVersionTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: compilation failure — `AppVersion` not defined.

- [ ] **Step 3: Implement AppVersion**

Create `TranscriberCore/AppVersion.swift`:

```swift
import Foundation

public enum AppVersion {

    /// Tag-based version: "0.6.1". Falls back to "dev" when not bundled.
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Full git description: "v0.6.1-12-ga3f9c12". Falls back to "unknown".
    public static var gitDescription: String {
        Bundle.main.infoDictionary?["ATGitDescription"] as? String ?? "unknown"
    }

    /// Short commit hash parsed from gitDescription: "a3f9c12".
    public static var commitHash: String? {
        parseCommitHash(from: gitDescription)
    }

    /// Human-friendly string for About panel: "0.6.1 (a3f9c12)".
    public static var displayString: String {
        formatDisplay(version: version, gitDescription: gitDescription)
    }

    // MARK: - Parsing (internal, exposed for testing)

    /// Extract short commit hash from git describe output.
    /// "v0.6.1-12-ga3f9c12" -> "a3f9c12"
    /// "a3f9c12-dirty" -> "a3f9c12"
    /// "v0.7.0" -> nil (on tag, no hash in string)
    static func parseCommitHash(from description: String) -> String? {
        // Pattern: vX.Y.Z-N-gHASH[-dirty]
        let parts = description.split(separator: "-")
        for (i, part) in parts.enumerated() {
            if part.hasPrefix("g"), part.count >= 7,
               part.dropFirst().allSatisfy(\.isHexDigit) {
                return String(part.dropFirst())
            }
            // Bare hash (no tags): "a3f9c12" or "a3f9c12-dirty"
            if i == 0, !part.contains("."),
               part.count >= 7, part.allSatisfy(\.isHexDigit) {
                return String(part)
            }
        }
        return nil
    }

    /// Extract commit distance from tag.
    /// "v0.6.1-12-ga3f9c12" -> 12
    /// "v0.7.0" -> 0 (on tag)
    /// "a3f9c12" -> nil (no tag)
    static func parseCommitDistance(from description: String) -> Int? {
        let parts = description.split(separator: "-")
        // Exactly on a tag: "v0.7.0"
        if parts.count == 1 && parts[0].contains(".") {
            return 0
        }
        // "v0.6.1-12-ga3f9c12[-dirty]"
        if parts.count >= 3,
           let distance = Int(parts[parts.count >= 4 && parts.last == "dirty" ? parts.count - 3 : parts.count - 2]) {
            return distance
        }
        return nil
    }

    /// Format display string from version and git description.
    static func formatDisplay(version: String, gitDescription: String) -> String {
        if gitDescription == "unknown" { return version }

        let isDirty = gitDescription.hasSuffix("-dirty")

        guard let hash = parseCommitHash(from: gitDescription) else {
            // Exactly on tag, clean
            return version
        }

        let suffix = isDirty ? "\(hash)-dirty" : hash
        return "\(version) (\(suffix))"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
swift test --filter AppVersionTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: all 11 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/AppVersion.swift SwiftTests/TranscriberTests/AppVersionTests.swift
git commit -m "feat: AppVersion — runtime version reader with git describe parsing"
```

---

### Task 2: Build-time version injection in package_app.sh

**Files:**
- Modify: `package_app.sh`

- [ ] **Step 1: Verify current plutil works**

Run:
```bash
plutil -help 2>&1 | head -3
```

Expected: plutil usage info (confirms tool is available).

- [ ] **Step 2: Add version injection to package_app.sh**

Insert after the `echo "==> Assembling $APP ..."` line and before the `rm -rf "$APP"` line, add a version injection block. Also modify the plist copy to use a temp copy with injected values.

Replace the Info.plist copy section. The new flow:
1. Compute git version values
2. Copy Info.plist to a temp location
3. Inject values via plutil
4. Use the temp copy in the bundle

Add this block after `echo "==> Assembling $APP ..."` and before `rm -rf "$APP"`:

```bash
# ── Compute version from git ─────────────────────────────────────────────────
GIT_DESCRIPTION="$(git describe --tags --always --dirty 2>/dev/null || echo 'unknown')"
# Strip 'v' prefix for CFBundleShortVersionString: "v0.6.1" -> "0.6.1"
TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo '')"
if [[ -n "$TAG" ]]; then
    VERSION="${TAG#v}"
else
    VERSION="0.0.0"
fi
# Commit distance for CFBundleVersion: "v0.6.1-12-ga3f9c12" -> "12", on tag -> "0"
if [[ "$GIT_DESCRIPTION" == *-*-g* ]]; then
    # Has distance component
    DISTANCE="$(echo "$GIT_DESCRIPTION" | sed -E 's/^v?[0-9]+\.[0-9]+\.[0-9]+-([0-9]+)-g.*/\1/')"
else
    DISTANCE="0"
fi

echo "   Version: $VERSION (distance: $DISTANCE, git: $GIT_DESCRIPTION)"
```

Then replace the Info.plist copy line:
```bash
cp packaging/Info.plist                  "$CONTENTS/Info.plist"
```

With:
```bash
# Info plist with version injection
cp packaging/Info.plist "$CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$DISTANCE" "$CONTENTS/Info.plist"
plutil -insert ATGitDescription -string "$GIT_DESCRIPTION" "$CONTENTS/Info.plist"
```

- [ ] **Step 3: Test the injection**

Run:
```bash
bash package_app.sh 2>&1 | grep -E "Version:|Assembling"
plutil -p dist/AudioTranscribe.app/Contents/Info.plist | grep -E "ATGitDescription|CFBundleVersion|CFBundleShortVersionString"
```

Expected output should show the injected git values — `ATGitDescription` with the full describe string, `CFBundleShortVersionString` with the tag version, `CFBundleVersion` with the distance number.

- [ ] **Step 4: Commit**

```bash
git add package_app.sh
git commit -m "feat: inject git version info into Info.plist at build time"
```

---

### Task 3: Add software_version to TranscriptAssembler

**Files:**
- Modify: `TranscriberCore/TranscriptAssembler.swift`
- Modify: `SwiftTests/TranscriberTests/TranscriptAssemblerTests.swift`

- [ ] **Step 1: Add test for software_version in metadata**

Add to `SwiftTests/TranscriberTests/TranscriptAssemblerTests.swift`:

```swift
@Test func assembleIncludesSoftwareVersion() {
    let json = TranscriptAssembler.assemble(
        segments: [],
        audioPaths: [URL(fileURLWithPath: "/tmp/a.wav")],
        outputFormat: "json",
        language: "en",
        numSpeakers: nil,
        diarization: true,
        dualStream: false
    )
    let metadata = json["metadata"] as? [String: Any]
    // In tests, Bundle.main won't have ATGitDescription, so falls back to "unknown"
    #expect(metadata?["software_version"] as? String != nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
swift test --filter TranscriptAssemblerTests/assembleIncludesSoftwareVersion -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: FAIL — `software_version` key not present in metadata.

- [ ] **Step 3: Add software_version to TranscriptAssembler.assemble()**

In `TranscriberCore/TranscriptAssembler.swift`, add to the `metadata` dict construction (after the `"dual_stream"` line):

```swift
"software_version": AppVersion.gitDescription,
```

- [ ] **Step 4: Run all TranscriptAssembler tests**

Run:
```bash
swift test --filter TranscriptAssemblerTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```

Expected: all 5 tests pass (4 existing + 1 new).

- [ ] **Step 5: Commit**

```bash
git add TranscriberCore/TranscriptAssembler.swift SwiftTests/TranscriberTests/TranscriptAssemblerTests.swift
git commit -m "feat: add software_version to transcript metadata (#42)"
```

---

### Task 4: About menu item in MenuView

**Files:**
- Modify: `TranscriberApp/Views/MenuView.swift`

- [ ] **Step 1: Add About menu item**

In `TranscriberApp/Views/MenuView.swift`, add a menu item before the Quit button. Find this block:

```swift
        Divider()

        Button("Quit") {
```

Replace with:

```swift
        Divider()

        Button("About Audio Transcribe") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(options: [
                .version: AppVersion.displayString,
                .applicationVersion: "",
            ])
        }

        Button("Quit") {
```

Notes:
- `.version` maps to the main version line in the About panel.
- `.applicationVersion` is set to empty string to suppress the default `CFBundleVersion` display (which would show the commit distance number with no context). The `displayString` already includes all the info the user needs.
- `NSApp.activate(ignoringOtherApps: true)` brings the panel to front since menu bar apps are background agents (LSUIElement).

- [ ] **Step 2: Build to verify compilation**

Run:
```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Manual test**

After next `dev.py` build, verify:
- "About Audio Transcribe" menu item appears above Quit
- Clicking it shows native About panel with version and commit hash
- Panel comes to foreground

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/Views/MenuView.swift
git commit -m "feat: add About menu item with version info (#33)"
```

---

### Task 5: Update spec and close

- [ ] **Step 1: Update the spec with CFBundleVersion commit distance decision**

Already done during brainstorming.

- [ ] **Step 2: Commit the updated spec**

```bash
git add docs/superpowers/specs/2026-04-10-version-infrastructure-design.md
git commit -m "docs: update version spec with commit distance for CFBundleVersion"
```
