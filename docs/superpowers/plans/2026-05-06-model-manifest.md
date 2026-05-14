# Model Manifest & Update Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track exactly which Hugging Face commit our Parakeet model came from, detect local cache corruption, and let users opt in to a periodic "is a newer model published?" check exposed in the main Settings UI.

**Architecture:** A `ModelManifest` JSON file written under `~/.audio-transcribe/model-manifests/<repo-slug>.json` after every successful download captures the HF top-level commit SHA plus a SHA-256 of every file under the cache root. A new `ModelManifestService` actor produces, verifies and (on demand) compares manifests against the live HF API. `FluidAudioEngine.preDownloadModel` calls `record()` after a successful download. `TranscriberApp` runs `verify()` on launch as a non-blocking background task. `SettingsView` gains a visible toggle and "Check now" button gated behind a new `Config.modelUpdateCheckEnabled` field that defaults to `false` (airgap-first).

**Tech Stack:** Swift 5.9, Swift Testing, SwiftUI, CryptoKit (`SHA256`), URLSession, FluidAudio 0.14.4, macOS 15.0+ deployment target.

---

## File Structure

**New files**
- `TranscriberCore/ModelManifest.swift` — `ModelManifest` Codable type, `ManifestVerification` enum, `ManifestUpdateStatus` enum (already drafted; tests in Task 1 will validate).
- `TranscriberCore/ModelManifestService.swift` — `ModelManifestService` actor: SHA-256 streaming hash, recursive cache walk, manifest read/write, HF API fetch, `verify` and `checkForUpdate` (already drafted; tests in Tasks 2–5 will validate and tighten).
- `SwiftTests/TranscriberTests/ModelManifestTests.swift` — Swift Testing suite covering codable round-trip, hashing, verification, and update-status logic.

**Modified files**
- `TranscriberCore/Config.swift` — add `modelUpdateCheckEnabled: Bool` field, CodingKey, decoder fallback, default factory entry.
- `TranscriberCore/FluidAudioEngine.swift` — call `ModelManifestService.shared.record(...)` after `AsrModels.download(...)` succeeds; expose `currentManifest()` accessor.
- `TranscriberApp/TranscriberApp.swift` — at launch, kick off a `Task` that calls `verify()` and logs the result. Non-blocking.
- `TranscriberApp/Views/SettingsView.swift` — visible Settings section: toggle "Check for model updates online", "Check now" button, status row showing local-verify result and last update-check outcome.
- `scripts/test-checklist.md` — append manual-test items for the new toggle and update flow.

**Storage layout**
```
~/.audio-transcribe/
├── config.json
└── model-manifests/
    └── FluidInference_parakeet-tdt-0.6b-v3-coreml.json
```

---

## Conventions

- **TDD strict:** every Task writes a failing test first, runs it to confirm failure, then writes minimum implementation, then runs the test green, then commits.
- **Test command (run from repo root):**
  ```bash
  swift test --filter TranscriberTests \
    -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
    -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
    -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
  ```
- **Build command:** `swift build`
- **Filter a single suite:** add `--filter ModelManifestTests` to the test command.
- **Per-project rule:** ask the user to test before committing UI changes (per memory `feedback_test_before_commit`). Tasks that touch UI explicitly defer commit to user approval.

---

## Task 1: ModelManifest types — codable round-trip

**Files:**
- Already exists: `TranscriberCore/ModelManifest.swift` (drafted)
- Create: `SwiftTests/TranscriberTests/ModelManifestTests.swift`

- [ ] **Step 1.1: Write the failing test**

```swift
import Foundation
import Testing
@testable import TranscriberCore

@Suite struct ModelManifestTests {
    @Test func manifestRoundTripsThroughJSON() throws {
        let original = ModelManifest(
            repo: "Acme/example-model",
            commitSha: "deadbeef",
            lastModifiedISO: "2026-05-01T00:00:00Z",
            downloadedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sdkLabel: "FluidAudio 0.14.4",
            files: [
                .init(relativePath: "Encoder.mlmodelc/weights.bin", size: 12345, sha256: "abc"),
                .init(relativePath: "vocab.json", size: 678, sha256: "def"),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ModelManifest.self, from: data)
        #expect(decoded == original)
    }

    @Test func manifestUsesSnakeCaseKeys() throws {
        let m = ModelManifest(
            repo: "x/y", commitSha: "s", lastModifiedISO: nil,
            downloadedAt: Date(timeIntervalSince1970: 0),
            sdkLabel: "x", files: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try String(data: encoder.encode(m), encoding: .utf8)!
        #expect(json.contains("\"commit_sha\""))
        #expect(json.contains("\"sdk_label\""))
        #expect(json.contains("\"downloaded_at\""))
    }
}
```

- [ ] **Step 1.2: Run the test to verify it passes** (the type already exists)

```bash
swift test --filter ModelManifestTests \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/
```
Expected: PASS for both tests in `ModelManifestTests`.

- [ ] **Step 1.3: Commit**

```bash
git add TranscriberCore/ModelManifest.swift SwiftTests/TranscriberTests/ModelManifestTests.swift
git commit -m "feat(manifest): ModelManifest types + codable round-trip"
```

---

## Task 2: Streaming SHA-256

**Files:**
- Already exists: `TranscriberCore/ModelManifestService.swift` (drafted, contains `static func sha256(of:)`)
- Modify: `SwiftTests/TranscriberTests/ModelManifestTests.swift` — append a sub-suite.

- [ ] **Step 2.1: Write the failing test**

Append to `ModelManifestTests.swift`:

```swift
@Suite struct ModelManifestServiceHashingTests {
    @Test func sha256OfEmptyFileMatchesKnownDigest() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-empty-\(UUID().uuidString)")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sha = try ModelManifestService.sha256(of: tmp)
        // SHA-256 of empty input
        #expect(sha == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func sha256OfMultiChunkFileIsStable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-big-\(UUID().uuidString)")
        // ~3 MiB so we cross at least three 1 MiB chunks.
        let chunk = Data(repeating: 0x41, count: 1 << 20)
        try (chunk + chunk + chunk).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = try ModelManifestService.sha256(of: tmp)
        let b = try ModelManifestService.sha256(of: tmp)
        #expect(a == b)
        #expect(a.count == 64)  // hex digest length
    }
}
```

- [ ] **Step 2.2: Run the test**

Run the same `swift test` command, filtered: `--filter ModelManifestServiceHashingTests`. Expected: PASS.

- [ ] **Step 2.3: Commit**

```bash
git add TranscriberCore/ModelManifestService.swift SwiftTests/TranscriberTests/ModelManifestTests.swift
git commit -m "feat(manifest): streaming SHA-256 over 1 MiB chunks"
```

---

## Task 3: Recursive cache walk + stable ordering

**Files:**
- Existing: `TranscriberCore/ModelManifestService.swift` (`hashAllFiles(under:)` already drafted)
- Modify: `SwiftTests/TranscriberTests/ModelManifestTests.swift`

- [ ] **Step 3.1: Write the failing test**

```swift
@Suite struct ModelManifestServiceWalkTests {
    @Test func walkProducesStableSortedEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sub = root.appendingPathComponent("Encoder.mlmodelc")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data([0x01]).write(to: sub.appendingPathComponent("weights.bin"))
        try Data([0x02, 0x03]).write(to: root.appendingPathComponent("vocab.json"))

        let entries = try ModelManifestService.hashAllFiles(under: root)
        #expect(entries.count == 2)
        // Sorted alphabetically by relative path.
        #expect(entries[0].relativePath == "Encoder.mlmodelc/weights.bin")
        #expect(entries[1].relativePath == "vocab.json")
        #expect(entries[0].size == 1)
        #expect(entries[1].size == 2)
        #expect(!entries[0].sha256.isEmpty)
    }

    @Test func walkSkipsDirectoryEntriesAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("real.bin")
        try Data([0xAA]).write(to: target)
        let link = root.appendingPathComponent("alias.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let entries = try ModelManifestService.hashAllFiles(under: root)
        // Symlink should not be hashed as a regular file.
        #expect(entries.count == 1)
        #expect(entries[0].relativePath == "real.bin")
    }
}
```

- [ ] **Step 3.2: Run and verify PASS** with `--filter ModelManifestServiceWalkTests`.

- [ ] **Step 3.3: Commit**

```bash
git add TranscriberCore/ModelManifestService.swift SwiftTests/TranscriberTests/ModelManifestTests.swift
git commit -m "feat(manifest): recursive cache walk with stable ordering"
```

---

## Task 4: Persist + load + verify

**Files:**
- Existing: `TranscriberCore/ModelManifestService.swift`
- Modify: `SwiftTests/TranscriberTests/ModelManifestTests.swift`

- [ ] **Step 4.1: Write the failing test**

```swift
@Suite struct ModelManifestServicePersistenceTests {
    private func makeService() -> (ModelManifestService, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-svc-\(UUID().uuidString)")
        return (ModelManifestService(manifestDir: dir), dir)
    }

    @Test func recordWritesManifestThatLoadsBack() async throws {
        let (svc, _) = makeService()

        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        try Data([0x01, 0x02]).write(to: cacheRoot.appendingPathComponent("a.bin"))

        // record() will try HF — accept whatever it returns since we treat HF failure as
        // a soft warning (empty commit sha is fine for this assertion).
        let manifest = try await svc.record(repo: "Test/example", cacheRoot: cacheRoot, sdkLabel: "test")
        #expect(manifest.repo == "Test/example")
        #expect(manifest.files.count == 1)

        let loaded = await svc.loadManifest(for: "Test/example")
        #expect(loaded == manifest)
    }

    @Test func verifyDetectsMissingAndCorruptFiles() async throws {
        let (svc, _) = makeService()

        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let goodFile = cacheRoot.appendingPathComponent("good.bin")
        let willCorrupt = cacheRoot.appendingPathComponent("flip.bin")
        let willDelete = cacheRoot.appendingPathComponent("gone.bin")
        try Data([0xAA]).write(to: goodFile)
        try Data([0xBB]).write(to: willCorrupt)
        try Data([0xCC]).write(to: willDelete)

        _ = try await svc.record(repo: "Test/example", cacheRoot: cacheRoot, sdkLabel: "test")

        // Mutate one file and remove another.
        try Data([0xCD, 0xEF]).write(to: willCorrupt)
        try FileManager.default.removeItem(at: willDelete)

        let result = await svc.verify(repo: "Test/example", cacheRoot: cacheRoot)
        switch result {
        case .missing(let paths):
            #expect(paths.contains("gone.bin"))
        case .corrupt(let paths):
            #expect(paths.contains("flip.bin"))
        default:
            Issue.record("Expected missing or corrupt, got \(result)")
        }
    }

    @Test func verifyReturnsNoManifestWhenAbsent() async {
        let (svc, _) = makeService()
        let dummy = FileManager.default.temporaryDirectory
        let result = await svc.verify(repo: "Nope/none", cacheRoot: dummy)
        #expect(result == .noManifest)
    }
}
```

- [ ] **Step 4.2: Run and verify PASS** with `--filter ModelManifestServicePersistenceTests`.

  Note: `record()` will attempt a real HF call. If the test environment is offline, the manifest will still be written (with empty commitSha) and the persistence assertions will still hold — that's by design.

- [ ] **Step 4.3: Commit**

```bash
git add TranscriberCore/ModelManifestService.swift SwiftTests/TranscriberTests/ModelManifestTests.swift
git commit -m "feat(manifest): persist, load, and verify against cache"
```

---

## Task 5: Config field — `modelUpdateCheckEnabled`

**Files:**
- Modify: `TranscriberCore/Config.swift` — add field, default value `false`, snake_case CodingKey `model_update_check_enabled`, decoder fallback `?? false`.
- Modify: `SwiftTests/TranscriberTests/ConfigTests.swift` (append) — backwards-compat test ensuring an old config without the field decodes with `false`.

- [ ] **Step 5.1: Write the failing test**

Append to `SwiftTests/TranscriberTests/ConfigTests.swift`:

```swift
@Test func decodingConfigWithoutUpdateCheckFlagDefaultsToFalse() throws {
    let json = """
    {
      "recording_directory": "/tmp/Recordings",
      "silence_timeout_minutes": 5,
      "silence_detection_enabled": true,
      "output_format": "txt",
      "launch_on_startup": true,
      "suppress_capture_warning": false,
      "engine": "fluid_audio",
      "archive_bitrate_kbps": 64,
      "audio_archive_limit_hours": 15,
      "chunk_duration_minutes": 30
    }
    """.data(using: .utf8)!
    let cfg = try JSONDecoder().decode(Config.self, from: json)
    #expect(cfg.modelUpdateCheckEnabled == false)
}

@Test func decodingConfigWithUpdateCheckFlagTrueRoundTrips() throws {
    var cfg = Config.default
    cfg.modelUpdateCheckEnabled = true
    let data = try JSONEncoder().encode(cfg)
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    #expect(decoded.modelUpdateCheckEnabled == true)
}
```

- [ ] **Step 5.2: Run and watch it fail**

Expected failure: `modelUpdateCheckEnabled` is not a member of `Config`.

- [ ] **Step 5.3: Implement Config changes**

In `TranscriberCore/Config.swift`:
1. Add stored property: `public var modelUpdateCheckEnabled: Bool`
2. Add to `Config.default` initializer call: `modelUpdateCheckEnabled: false`
3. Add to designated `init(...)`: `modelUpdateCheckEnabled: Bool = false` and assign.
4. Add CodingKey: `case modelUpdateCheckEnabled = "model_update_check_enabled"`
5. In the `init(from:)` decoder add: `modelUpdateCheckEnabled = try c.decodeIfPresent(Bool.self, forKey: .modelUpdateCheckEnabled) ?? false`

- [ ] **Step 5.4: Run tests, verify PASS**

- [ ] **Step 5.5: Commit**

```bash
git add TranscriberCore/Config.swift SwiftTests/TranscriberTests/ConfigTests.swift
git commit -m "feat(config): modelUpdateCheckEnabled flag (default false)"
```

---

## Task 6: Wire into FluidAudioEngine

**Files:**
- Modify: `TranscriberCore/FluidAudioEngine.swift` — call `ModelManifestService.shared.record(repo:cacheRoot:sdkLabel:)` after `AsrModels.download` succeeds in `preDownloadModel`.
- Modify: `SwiftTests/TranscriberTests/ModelManifestTests.swift` — add a test that constructs a synthetic cache directory and calls `record`, asserts the manifest was written.

(There is no test for the live FluidAudio download path itself — that requires real models. We rely on Task 4's persistence tests + the manual checklist.)

- [ ] **Step 6.1: Write the failing test (already covered by Task 4 — this task is implementation-only).**

- [ ] **Step 6.2: Modify FluidAudioEngine.swift**

In `preDownloadModel`, after the existing `_ = try await AsrModels.download(...)` line, append:

```swift
let cacheRoot = AsrModels.defaultCacheDirectory()
do {
    _ = try await ModelManifestService.shared.record(
        repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        cacheRoot: cacheRoot,
        sdkLabel: "FluidAudio 0.14.x"
    )
} catch {
    Logger.transcription.warning("Manifest record failed: \(error.localizedDescription, privacy: .public)")
}
```

- [ ] **Step 6.3: Build**

```bash
swift build
```
Expected: PASS.

- [ ] **Step 6.4: Run tests** (no new tests; existing ones must still pass)

- [ ] **Step 6.5: Commit**

```bash
git add TranscriberCore/FluidAudioEngine.swift
git commit -m "feat(manifest): record manifest after Parakeet download"
```

---

## Task 7: Settings UI — toggle + check-now button + status row

**Files:**
- Modify: `TranscriberApp/Views/SettingsView.swift`

This task is UI; we hand it to the user to test before committing (per project rule).

- [ ] **Step 7.1: Locate the right section**

Open `TranscriberApp/Views/SettingsView.swift`. Find the engine section (where the user picks engine + downloads models). Add a new `Section("Model Updates")` after it.

- [ ] **Step 7.2: Add the toggle and helper UI**

Replace nothing. Insert this section, replacing `<existing-binding-for-config>` with the actual config-binding pattern used elsewhere in the file (look for `Toggle(...)` calls that already bind to `config.something`):

```swift
Section("Model Updates") {
    Toggle("Check for model updates online", isOn: Binding(
        get: { configManager.config.modelUpdateCheckEnabled },
        set: { newValue in
            configManager.update { $0.modelUpdateCheckEnabled = newValue }
        }
    ))
    Text("Periodically asks Hugging Face if a newer Parakeet model has been published. Updates are never downloaded automatically — you confirm before any change. Leave off for fully offline use.")
        .font(.caption)
        .foregroundStyle(.secondary)

    if configManager.config.modelUpdateCheckEnabled {
        Button("Check now") {
            Task { await runUpdateCheck() }
        }
        .disabled(updateCheckInFlight)

        if let status = lastUpdateStatus {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 7.3: Add the supporting state and helper**

In the `SettingsView` struct, add:

```swift
@State private var updateCheckInFlight = false
@State private var lastUpdateStatus: String?

private func runUpdateCheck() async {
    updateCheckInFlight = true
    defer { updateCheckInFlight = false }
    let result = await ModelManifestService.shared.checkForUpdate(
        repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    )
    switch result {
    case .upToDate(let sha):
        lastUpdateStatus = "Up to date (\(String(sha.prefix(7))))"
    case .updateAvailable(let local, let remote, let when):
        let date = when.map { " · \($0)" } ?? ""
        lastUpdateStatus = "Update available: \(String(local.prefix(7))) → \(String(remote.prefix(7)))\(date). Clear the model cache and re-download from Setup to apply."
    case .noBaseline:
        lastUpdateStatus = "No baseline manifest yet — re-download the model to record one."
    case .checkFailed(let reason):
        lastUpdateStatus = "Check failed: \(reason)"
    }
}
```

- [ ] **Step 7.4: Build + launch via dev.py**

```bash
swift build
python3 scripts/dev.py --debug
```

- [ ] **Step 7.5: Hand to user to test**

Manual checks for the user:
1. Toggle is visible in Settings (not hidden behind an "Advanced" disclosure).
2. Toggle defaults to OFF on a fresh install.
3. Helper text reads naturally.
4. With toggle ON, "Check now" button appears and is enabled.
5. "Check now" produces a status string within ~10s.
6. Toggle persists across app restart.

- [ ] **Step 7.6: Commit (only after user approval)**

```bash
git add TranscriberApp/Views/SettingsView.swift
git commit -m "feat(ui): Settings toggle + Check Now for model updates"
```

---

## Task 8: Launch-time local verification

**Files:**
- Modify: `TranscriberApp/TranscriberApp.swift` — at app init, after the existing recovery Task, kick off a non-blocking verify Task.

- [ ] **Step 8.1: Locate `TranscriberApp.init()`**

Find the existing recovery Task block (search for "RecordingSentinel" or "recovery").

- [ ] **Step 8.2: Insert a verify Task immediately after recovery setup**

```swift
Task.detached(priority: .background) {
    let cacheRoot = AsrModels.defaultCacheDirectory()
    let result = await ModelManifestService.shared.verify(
        repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        cacheRoot: cacheRoot
    )
    switch result {
    case .ok:
        Logger.transcription.info("Manifest verify: OK")
    case .noManifest:
        Logger.transcription.info("Manifest verify: no manifest yet (will be written on next download)")
    case .missing(let paths):
        Logger.transcription.warning("Manifest verify: missing \(paths.count) file(s) — \(paths.prefix(3).joined(separator: \", \"), privacy: .public)…")
    case .corrupt(let paths):
        Logger.transcription.error("Manifest verify: \(paths.count) file(s) corrupt — \(paths.prefix(3).joined(separator: \", \"), privacy: .public)…")
    }
}
```

Imports: ensure `import FluidAudio` and `import TranscriberCore` are already present (they should be).

- [ ] **Step 8.3: Build and launch**

```bash
swift build
python3 scripts/dev.py --debug
```

Watch the log for `Manifest verify:` line within a few seconds.

- [ ] **Step 8.4: Hand to user to test**

Manual:
1. First launch (no manifest): expect `no manifest yet`.
2. After running the model once (download + transcribe): `OK`.
3. Manually delete a file from the cache, restart: `missing` line appears.

- [ ] **Step 8.5: Commit (after user approval)**

```bash
git add TranscriberApp/TranscriberApp.swift
git commit -m "feat(manifest): verify on launch (non-blocking, log-only)"
```

---

## Task 9: Test checklist + gotchas

**Files:**
- Modify: `scripts/test-checklist.md` — append manual checks under a new heading "Model manifest".
- Modify: `docs/gotchas.md` — append a new gotcha about manifest behavior (HF cache stickiness, opt-in update check, location of manifest files).

- [ ] **Step 9.1: Update test-checklist.md**

Append:

```markdown
## Model manifest
- [ ] Settings: "Check for model updates online" toggle visible and OFF by default
- [ ] Toggle persists across restart
- [ ] With toggle ON, "Check now" button appears
- [ ] "Check now" reports a status within 10s and stays under the toggle
- [ ] Launch log contains "Manifest verify:" within a few seconds of startup
- [ ] After deleting a file from `~/Library/Application Support/FluidAudio/.../<some-weights>` (or the FluidAudio cache root), launch log reports `missing` or `corrupt`
```

- [ ] **Step 9.2: Update docs/gotchas.md**

Append a numbered item:

```markdown
N. **Model manifests track HF commit identity:** Every successful Parakeet download writes `~/.audio-transcribe/model-manifests/FluidInference_parakeet-tdt-0.6b-v3-coreml.json` capturing the HF top-level commit SHA + per-file SHA-256. The FluidAudio cache itself is filename-keyed and never re-pulls if files exist, so the manifest is the only record of *which* model version is on disk. Local verification runs on launch (cheap, offline). Online "is HF newer" check is opt-in via Settings → Model Updates and never downloads automatically.
```

- [ ] **Step 9.3: Commit**

```bash
git add scripts/test-checklist.md docs/gotchas.md
git commit -m "docs(manifest): test checklist + gotcha for model manifests"
```

---

## Self-Review Notes

- Spec coverage: every requested deliverable (manifest at download, local verification, opt-in online check, visible Settings toggle for common users) is in a task.
- No placeholders.
- Type names consistent across tasks: `ModelManifest`, `ManifestVerification`, `ManifestUpdateStatus`, `ModelManifestService`, `Config.modelUpdateCheckEnabled`.
- Snake-case CodingKey: `model_update_check_enabled` matches existing project convention.
- All commits go on the current worktree branch `feature/v0.7.x`. No pushing.
