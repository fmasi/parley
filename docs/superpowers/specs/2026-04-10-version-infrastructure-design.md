# Version Infrastructure Design (#42 + #33)

**Date:** 2026-04-10
**Issues:** #42 (software version in transcript metadata), #33 (About section)

## Overview

Add version traceability to transcript JSON and a native About panel. Both share a single `AppVersion` utility backed by Info.plist values injected at build time.

## Version Source

`git describe --tags --always --dirty` provides the canonical version string:
- Tagged commit: `v0.7.0`
- After tag: `v0.7.0-3-ga3f9c12`
- Dirty worktree: `v0.7.0-3-ga3f9c12-dirty`
- No tags: `a3f9c12`

No separate build number — git describe already encodes commit distance from tag.

## Build-Time Injection

`package_app.sh` injects values into `packaging/Info.plist` before `swift build`:

| Plist key | Source | Example |
|---|---|---|
| `CFBundleShortVersionString` | latest tag, strip `v` prefix, fallback `0.0.0` | `0.6.1` |
| `ATGitDescription` | `git describe --tags --always --dirty` | `v0.6.1-12-ga3f9c12` |

`CFBundleVersion` set to same value as `CFBundleShortVersionString` (Apple requires it).

Values are injected via `plutil` or `sed` on a working copy — the source `packaging/Info.plist` is not modified in git.

`scripts/dev.py` needs no changes — it already delegates to `package_app.sh`.

## Runtime: AppVersion (TranscriberCore)

```swift
public enum AppVersion {
    /// Tag-based version: "0.6.1"
    public static var version: String

    /// Full git description: "v0.6.1-12-ga3f9c12"
    public static var gitDescription: String

    /// Short commit hash: "a3f9c12"
    public static var commitHash: String

    /// Human-friendly: "0.6.1 (a3f9c12)"
    public static var displayString: String
}
```

Reads from `Bundle.main.infoDictionary`. Returns `"dev"` / `"unknown"` when not running from a bundle (plain `swift test`).

## #42: Transcript Metadata

`TranscriptAssembler.assemble()` adds to metadata dict:

```json
{
  "metadata": {
    "software_version": "v0.6.1-12-ga3f9c12",
    ...
  }
}
```

No new parameter — `AppVersion.gitDescription` is read directly.

## #33: About Panel

`MenuView` gains an "About Audio Transcribe" item that calls `NSApp.orderFrontStandardAboutPanel(options:)` with:
- Version from `AppVersion.displayString`
- App icon from bundle

Native macOS About dialog — no custom view.

## Files to Create/Modify

- **New:** `TranscriberCore/AppVersion.swift`
- **Modify:** `package_app.sh` — inject git info into plist
- **Modify:** `TranscriberCore/TranscriptAssembler.swift` — add `software_version`
- **Modify:** `TranscriberApp/Views/MenuView.swift` — add About menu item
- **New:** `SwiftTests/TranscriberTests/AppVersionTests.swift`

## Testing

- `AppVersionTests`: verify parsing of git description formats (tagged, post-tag, dirty, hash-only)
- `TranscriptAssembler` existing tests: verify `software_version` appears in metadata
- Manual: About panel shows correct version after `dev.py` build
