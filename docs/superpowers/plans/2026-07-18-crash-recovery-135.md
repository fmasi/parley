# Crash-Recovery Rehydration (#135) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A crash on a long (>1 chunk) recording must produce a complete, correctly-ordered, correctly-attributed transcript from the data already on disk — never silently discard the session.

**Architecture:** The chunked `finalize(sessionState:outputDirectory:config:)` already does the right thing (offset-aware merge via `TranscriptMerger` + cross-chunk identity via `SpeakerReconciler`) and is decoupled from any live pipeline — it takes a `SessionState` value. The defect: after an app relaunch, `recoverIfNeeded` restarts capture but never rebuilds the pipeline, so the stop path falls through to `TranscriptionRunner.run()`, which stats a session-start WAV that `AudioArchiver` deleted at the first rotation (→ "No usable audio files", session discarded) and, when it does find files, applies no time offsets (H2) and never reconciles speakers (H3). The fix routes recovery through `finalize()` by reading `session.json` (rewritten after every chunk), seeding a `ChunkProcessor` with that state, re-ingesting the un-archived orphan chunk WAV(s) still on disk, and finalizing. `run()` is kept only for genuine single-file/CLI input and separately corrected for offsets + reconciliation.

**Prerequisite restructure (Task 1):** `ChunkProcessor`, `TranscriptionRunner`, and `ChunkRotator` currently live in the **executable** target `TranscriberApp`, which unit tests cannot import — so the recovery pipeline is untestable and today's `ChunkProcessorTests`/`ChunkRotatorTests` test hand-copied logic. Task 1 relocates those three files into the `TranscriberCore` library (behavior-neutral) behind one new protocol seam, so every later task gets real unit tests driving the real classes.

**Tech Stack:** Swift 5 (tools 5.9), Swift Testing (not XCTest), `@MainActor`, `os.Logger`. Build: `swift build`. Test: the long invocation in CLAUDE.md.

## Global Constraints

- macOS 15.0+; Apple Silicon. No Xcode — CommandLineTools only.
- Tests use **Swift Testing** (`@Test`, `#expect`, `Issue.record`) in `SwiftTests/TranscriberTests/` (NOT `Tests/` — APFS case collision).
- Test run command (verbatim): `swift test --filter TranscriberTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks/ -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib/`
- Reuse the fixed data model, do not re-invent: `SessionState`/`ProcessedChunk` (`TranscriberCore/ChunkSession.swift`), `ChunkRotator.FinalizedChunk` (`{index, systemPath, micPath, startTime}`), `RecordingSentinel`.
- `session.json` at `<outputDirectory>/session.json`; rewritten after every completed chunk; deleted by `finalize()` on success. Chunk WAVs `<base>-<N>.wav`/`<base>-<N>_mic.wav`; archives `<base>-<N>.m4a`; `<base>` == `SessionState.sessionId`.
- Airgap holds — no new network/telemetry. Keep existing log privacy posture (`privacy: .private` for names/paths).
- Process: relocation (Task 1) is behavior-neutral and MUST keep the existing suite green with zero logic change. The #135 fix is a **MINOR** (it changes what recovered transcripts say). Council → CI → device test before merge.
- **Keep the relocation commit (Task 1) free of any behavior change.** Moving files + `public` annotations + the protocol seam only. No logic edits.

---

## File Structure

- **Move (Task 1):** `TranscriberApp/Services/{ChunkProcessor,TranscriptionRunner,ChunkRotator}.swift` → `TranscriberCore/`. Directory-scoped targets mean `Package.swift` is unchanged.
- **Create (Task 1):** `ChunkRotationClient` protocol in `TranscriberCore/` (new file `TranscriberCore/ChunkRotationClient.swift`) — the one app→core inversion (XPC client). App-side: one empty conformance extension on `AudioCaptureClient`.
- **Delete (Task 1):** `SwiftTests/TranscriberTests/ChunkProcessorTests.swift`, `ChunkRotatorTests.swift` — they characterize hand-copied logic; replaced by real tests here + in later tasks.
- **Create `TranscriberCore/CrashRecoveryPlanner.swift`** (Task 2) — pure orphan discovery + recoverability.
- **Create `TranscriberCore/ChunkedSessionRecovery.swift`** (Task 3) — rehydrate→finalize executor (now in Core; unit-testable with fakes).
- **Modify `TranscriberApp/TranscriberApp.swift` + `Views/MenuView.swift`** (Task 4) — wire recovery into relaunch + stop.
- **Modify `TranscriberCore/TranscriptionRunner.swift`** (Tasks 5–6, post-move) — `run()` offsets (H2) + speaker reconciliation (H3); extract pure helpers.
- **Modify `TranscriberCore/SegmentDiscovery.swift`** (Task 5) — correct the false "timestamps are absolute" doc.
- **Create tests:** `CrashRecoveryPlannerTests`, `ChunkedSessionRecoveryTests`, `TranscriptionRunnerTests`, and replacements for the deleted `ChunkProcessorTests`/`ChunkRotatorTests` that drive the real (now-Core) classes.

---

## Task 1: Relocate the chunk pipeline into `TranscriberCore` (behavior-neutral)

**Files:**
- Move: `TranscriberApp/Services/ChunkProcessor.swift` → `TranscriberCore/ChunkProcessor.swift`
- Move: `TranscriberApp/Services/TranscriptionRunner.swift` → `TranscriberCore/TranscriptionRunner.swift`
- Move: `TranscriberApp/Services/ChunkRotator.swift` → `TranscriberCore/ChunkRotator.swift`
- Create: `TranscriberCore/ChunkRotationClient.swift`
- Modify: `TranscriberApp/Services/AudioCaptureClient.swift` (add empty conformance)
- Delete: `SwiftTests/TranscriberTests/ChunkProcessorTests.swift`, `SwiftTests/TranscriberTests/ChunkRotatorTests.swift`

**Interfaces:**
- Produces: the three classes now `public` in `TranscriberCore` with `public` inits/members that App call sites use (`TranscriptionRunner`: init, `run`, `finalize`, `setupChunkedPipeline`, `startChunkRotation`, `stopChunkRotation`, `teardownChunkedPipeline`, `chunkRotator`, `chunkProcessor`, `TranscriptionResult`; `ChunkProcessor`: init, `processChunk`, `processLastChunk`, `awaitAllProcessed`, `getSessionState`; `ChunkRotator`: init, `FinalizedChunk`, `currentBaseName`, `currentChunkInfo`, `recoverFromCrash`, `stop`, and its start/rotation API). `ChunkRotationClient` protocol.

- [ ] **Step 1: Add the seam protocol**

`TranscriberCore/ChunkRotationClient.swift`:
```swift
import Foundation

/// The one capability ChunkRotator needs from the XPC audio client. Defined in Core so the
/// pipeline can live in Core (and be unit-tested with a fake) while the concrete NSXPC client
/// stays in the app target. AudioCaptureClient already has this exact signature.
@MainActor
public protocol ChunkRotationClient: AnyObject {
    func rotateChunk(outputDirectory: String, newBaseName: String) async throws
        -> (systemPath: String, micPath: String)
}
```

- [ ] **Step 2: Move the three files** (`git mv`) and change `ChunkRotator`/`TranscriptionRunner` to hold `any ChunkRotationClient` where they held `AudioCaptureClient`.

```bash
git mv TranscriberApp/Services/ChunkProcessor.swift TranscriberCore/ChunkProcessor.swift
git mv TranscriberApp/Services/TranscriptionRunner.swift TranscriberCore/TranscriptionRunner.swift
git mv TranscriberApp/Services/ChunkRotator.swift TranscriberCore/ChunkRotator.swift
```
In `ChunkRotator.swift` and `TranscriptionRunner.setupChunkedPipeline`, change the `captureClient` parameter/stored type from `AudioCaptureClient` to `any ChunkRotationClient`. No call-body changes — `rotateChunk` is the only method used.

- [ ] **Step 3: Add `public` until it compiles + the app-side conformance**

Add `public` to each moved type, its init, and every member the app calls (see Interfaces). In `AudioCaptureClient.swift`:
```swift
extension AudioCaptureClient: ChunkRotationClient {}   // signature already matches rotateChunk(...)
```

- [ ] **Step 4: Delete the two characterization test suites**

```bash
git rm SwiftTests/TranscriberTests/ChunkProcessorTests.swift SwiftTests/TranscriberTests/ChunkRotatorTests.swift
```

- [ ] **Step 5: Build + run the FULL existing suite**

Run `swift build` then the full test command. Expected: `Build complete!`; suite green (minus the two deleted suites — no other test changes). This proves the move is behavior-neutral.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(core): move chunk pipeline into TranscriberCore behind ChunkRotationClient (#135 prep)"
```

> Task 3 (below) recreates real `ChunkProcessor`/`ChunkRotator` tests that drive the actual classes with a fake `ChunkRotationClient` — this task only removes the copies; it does not leave those types permanently untested.

---

## Task 2: `CrashRecoveryPlanner` — pure orphan discovery + recoverability

**Files:**
- Create: `TranscriberCore/CrashRecoveryPlanner.swift`
- Create: `SwiftTests/TranscriberTests/RecoveryFixtures.swift` (shared fixtures)
- Test: `SwiftTests/TranscriberTests/CrashRecoveryPlannerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum CrashRecoveryPlanner {
      public struct OrphanChunk: Equatable { public let index: Int; public let baseName: String; public init(index: Int, baseName: String) }
      public static func orphanChunks(outputDirectory: URL, sessionId: String, completedIndices: Set<Int>) -> [OrphanChunk]
      public static func isChunkedSessionRecoverable(outputDirectory: URL, sessionId: String) -> Bool
  }
  ```
- Produces (fixtures): `enum RecoveryFixtures { static func writeSessionJSON(dir:URL, sessionId:String, meetingStart:Date, chunkIndices:[Int]) throws; static func writeFakeWav(at:URL, seconds:Double) throws }`

- [ ] **Step 1: Write `RecoveryFixtures.swift`**

```swift
import Foundation
@testable import TranscriberCore

enum RecoveryFixtures {
    static func writeSessionJSON(dir: URL, sessionId: String, meetingStart: Date, chunkIndices: [Int]) throws {
        let chunks = chunkIndices.map { i in
            ProcessedChunk(index: i, startTime: meetingStart.addingTimeInterval(Double(i) * 60),
                audioPath: "\(sessionId)-\(i).m4a",
                segments: [.init(start: 0, end: 5, text: "chunk \(i)", speaker: "Speaker 1", source: "remote", qualityScore: 1)],
                speakerDatabase: ["Speaker 1": [Float(i), 0, 0]], localSpeakerDatabase: [:],
                echoSegmentsRemoved: 0, isDualStream: false)
        }
        let state = SessionState(sessionId: sessionId, meetingStart: meetingStart, engine: "fluidAudio",
                                 chunkDurationMinutes: 1, chunks: chunks)
        try SessionState.write(state, directory: dir)
    }
    static func writeFakeWav(at url: URL, seconds: Double) throws {
        let sr = 48_000, ch = 1, bits = 16, frames = Int(seconds * 48_000), dataBytes = frames * ch * bits / 8
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var h = Data()
        h.append("RIFF".data(using: .ascii)!); h.append(le(UInt32(36 + dataBytes))); h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!); h.append(le(UInt32(16))); h.append(le(UInt16(1))); h.append(le(UInt16(ch)))
        h.append(le(UInt32(sr))); h.append(le(UInt32(sr * ch * bits / 8))); h.append(le(UInt16(ch * bits / 8))); h.append(le(UInt16(bits)))
        h.append("data".data(using: .ascii)!); h.append(le(UInt32(dataBytes))); h.append(Data(count: dataBytes))
        try h.write(to: url)
    }
}
```

- [ ] **Step 2: Write failing tests** — `CrashRecoveryPlannerTests.swift` (orphan = WAV not in session.json; multiple orphans ascending; completed WAV not an orphan; recoverable when session.json has chunks; not recoverable when empty dir). Use the test bodies from the prior plan revision (identical semantics), driving `CrashRecoveryPlanner`.

- [ ] **Step 3: Run tests, verify they fail** (`CrashRecoveryPlanner` undefined).

- [ ] **Step 4: Implement `CrashRecoveryPlanner`** (pure `FileManager` reads):

```swift
import Foundation

public enum CrashRecoveryPlanner {
    public struct OrphanChunk: Equatable {
        public let index: Int; public let baseName: String
        public init(index: Int, baseName: String) { self.index = index; self.baseName = baseName }
    }
    public static func orphanChunks(outputDirectory: URL, sessionId: String, completedIndices: Set<Int>) -> [OrphanChunk] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
        let prefix = "\(sessionId)-"
        var found: [OrphanChunk] = []
        for name in names where name.hasSuffix(".wav") && !name.hasSuffix("_mic.wav") && name.hasPrefix(prefix) {
            let stem = String(name.dropLast(4))
            guard let idx = Int(stem.dropFirst(prefix.count)), !completedIndices.contains(idx) else { continue }
            found.append(OrphanChunk(index: idx, baseName: stem))
        }
        return found.sorted { $0.index < $1.index }
    }
    public static func isChunkedSessionRecoverable(outputDirectory: URL, sessionId: String) -> Bool {
        let state = SessionState.read(directory: outputDirectory)
        if let state, !state.chunks.isEmpty { return true }
        let completed = Set(state?.chunks.map(\.index) ?? [])
        return !orphanChunks(outputDirectory: outputDirectory, sessionId: sessionId, completedIndices: completed).isEmpty
    }
}
```

- [ ] **Step 5: Run tests, verify pass.**
- [ ] **Step 6: Commit** — `feat(recovery): pure planner — orphan discovery + recoverability (#135)`

---

## Task 3: `ChunkedSessionRecovery` — rehydrate → re-ingest orphans → `finalize()` (now real unit tests)

**Files:**
- Create: `TranscriberCore/ChunkedSessionRecovery.swift`
- Test: `SwiftTests/TranscriberTests/ChunkedSessionRecoveryTests.swift`
- Also recreate (replacing the deleted suites): minimal real `ChunkProcessorTests`/`ChunkRotatorTests` driving the now-Core classes with a fake `ChunkRotationClient` and fake engine/diarizer.

**Interfaces:**
- Consumes: `CrashRecoveryPlanner`, `SessionState.read`, `ChunkProcessor(config:outputDirectory:sessionState:transcriber:diarizer:)`, `ChunkProcessor.processLastChunk/awaitAllProcessed/getSessionState`, `TranscriptionRunner.finalize`.
- Produces:
  ```swift
  @MainActor public enum ChunkedSessionRecovery {
      public static func recover(outputDirectory: URL, sessionId: String, config: Config,
          transcriber: any TranscriptionEngine, diarizer: (any DiarizationProvider)?,
          runner: TranscriptionRunner) async throws -> TranscriptionRunner.TranscriptionResult?
  }
  ```

- [ ] **Step 1: Write failing test** — seed `session.json` (chunks 0,1) + orphan `m-2.wav`/`_mic.wav`; a `FakeEngine`/`FakeDiarizer` (reuse Core test doubles if they exist, else add here); assert `recover` returns a result whose `jsonPath` exists and that `session.json` was deleted by finalize. Second test: empty dir → `nil`.
- [ ] **Step 2: Run, verify fails** (`ChunkedSessionRecovery` undefined).
- [ ] **Step 3: Implement** the executor (read base state or empty, compute orphans, seed `ChunkProcessor`, `processLastChunk` each orphan with a best-effort `startTime` = WAV creation date ?? `meetingStart + index*chunkDuration`, `awaitAllProcessed`, `getSessionState`, `finalize`; return `nil` when nothing to recover). Full code as in the prior plan revision, but with `public` and in Core.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Recreate real `ChunkProcessorTests`/`ChunkRotatorTests`** — a focused test each that drives the real class (e.g. `ChunkRotator.recoverFromCrash()` index math with a fake `ChunkRotationClient`; `ChunkProcessor` appending a processed chunk to a seeded `SessionState` with a `FakeEngine`). These replace the deleted characterization suites with tests of the real code.
- [ ] **Step 6: Run full suite, verify green.**
- [ ] **Step 7: Commit** — `feat(recovery): rehydrate session.json + re-ingest orphans + finalize, with real pipeline tests (#135 C1/C2)`

---

## Task 4: Wire recovery into the app — relaunch (Flow B) + stop path

**Files:** Modify `TranscriberApp/TranscriberApp.swift` (`recoverIfNeeded` Flow B) and `TranscriberApp/Views/MenuView.swift` (`stopRecording` fallback).

**Interfaces:** Consumes `ChunkedSessionRecovery.recover`, `CrashRecoveryPlanner.isChunkedSessionRecoverable`, the shared `TranscriptionRunner` + engine/diarizer factory.

> App-level `@MainActor` wiring around tested units — verified by Task 7's device test, not a new unit test (needs real engines + capture). Keep edits minimal; delegate all logic to the tested functions.

- [ ] **Step 1: `recoverIfNeeded` Flow B** — when XPC is dead and `CrashRecoveryPlanner.isChunkedSessionRecoverable(outputDirectory:sessionId:)`, call `ChunkedSessionRecovery.recover(...)` with real engines and set `appState.lastJsonPath`/`lastTranscriptPath`, delete the sentinel, return — instead of the stat-based single-file restart. Fall through to the existing single-file logic only when not recoverable. (Thread the shared runner + engine factory into `recoverIfNeeded`, which is `static` today.)
- [ ] **Step 2: `stopRecording` fallback branch** — when no live pipeline but a chunked `session.json` is recoverable, rehydrate+finalize; else keep the legacy `run()` for genuine single-file input.
- [ ] **Step 3: `swift build`** — clean, no warnings in touched files.
- [ ] **Step 4: Full suite green** (no regressions).
- [ ] **Step 5: Commit** — `feat(recovery): route relaunch + stop through chunked rehydration (#135 C1/C2)`

---

## Task 5: `run()` — cumulative per-segment time offsets (H2)

**Files:** Modify `TranscriberCore/TranscriptionRunner.swift` (post-move) + `TranscriberCore/SegmentDiscovery.swift` (doc fix). Test: `SwiftTests/TranscriberTests/TranscriptionRunnerTests.swift`.

**Interfaces:** Produces pure helper `public static func segmentStartOffsets(durations: [Double]) -> [Double]` (offsets[0]==0; offsets[k]==sum(durations[0..<k])).

- [ ] **Step 1: Write failing tests** — `segmentStartOffsets([60,45,30]) == [0,60,105]`; single segment `[42] -> [0]`. (Now compiles: `@testable import TranscriberCore`.)
- [ ] **Step 2: Run, verify fails.**
- [ ] **Step 3: Implement** `segmentStartOffsets` (`var acc=0; map { defer{acc+=$0}; return acc }`) and apply per-segment offset to each segment's `LabeledSegment.start/end` in `run()` before appending; derive per-segment duration from that segment's own max `end` (or WAV frame count). Segment 0 offset 0 (unchanged single-file behaviour).
- [ ] **Step 4: Fix the false `SegmentDiscovery` doc** ("timestamps are absolute" → per-segment WAVs are file-relative; `run()` applies cumulative offsets; a gap shifts later segments by the missing segment's unknown duration — state the limitation).
- [ ] **Step 5: Run tests + full suite, green.**
- [ ] **Step 6: Commit** — `fix(recovery): cumulative per-segment offsets in run() (#135 H2)`

---

## Task 6: `run()` — reconcile speakers across segments (H3)

**Files:** Modify `TranscriberCore/TranscriptionRunner.swift`. Test: `TranscriptionRunnerTests.swift` (add cases).

**Interfaces:** Consumes `SpeakerReconciler.reconcile`. Produces pure helper `reconcileRecoverySegments(databases:threshold:) -> [<segmentLocalKey>: <globalLabel>]`.

- [ ] **Step 1: Write failing test** — two segments each a different single speaker under key `Speaker 1` → reconciliation yields two distinct global speakers (`Set(mapping.values).count == 2`), not one concatenated embedding.
- [ ] **Step 2: Run, verify fails** (current code merges under one key with `existing + new`).
- [ ] **Step 3: Implement** — replace the `{ existing, new in existing + new }` DB merges with per-segment-namespaced keys fed to `SpeakerReconciler` (mirror how `finalize()` reconciles chunks); extract `reconcileRecoverySegments` as a pure, tested function; apply the mapping to relabel `allSegments` before writing.
- [ ] **Step 4: Run tests + full suite, green.**
- [ ] **Step 5: Commit** — `fix(recovery): reconcile speakers across run() segments (#135 H3)`

---

## Task 7: Verification — council, CI, device test

- [ ] **Step 1: Full suite green**, output pristine.
- [ ] **Step 2: Multi-agent council over the whole diff** before pushing (project process). Fix only findings that reduce to a RED test; decline opinions with a reply.
- [ ] **Step 3: Device test** (the real acceptance): record a >3-chunk meeting; **force-quit mid-chunk**; relaunch. Assert: a complete transcript covering all chunks incl. the orphan (not "No usable audio files"); timestamps monotonic across chunk boundaries (H2); two different speakers in different chunks are NOT one label (H3); `session.json` deleted afterward. Add these to `scripts/test-checklist.md`.
- [ ] **Step 4: Version** — recovered transcripts now say something different (and correct) → **MINOR** when v0.9.0 is cut.

---

## Self-Review Notes (author)

- **Spec coverage:** testability blocker → Task 1 (relocation); C1/C2 → Tasks 2–4; H2 → Task 5; H3 → Task 6; "TranscriptionRunner has no tests" → Tasks 3/5/6 add real tests driving the real (now-Core) class; the two hand-copied suites are deleted (Task 1) and replaced with real ones (Task 3).
- **Deliberate divergence from the issue's "make the sentinel track the live chunk index":** replaced by disk-scan orphan discovery (Task 2) — robust to a stale `chunkIndex`, no per-rotation sentinel writes. Flagged for the reviewer.
- **Relocation risk (Task 1):** behavior-neutral; every missed `public` is a compile error, not a runtime bug (per the Fable audit — 3 files, only `AudioCaptureClient` needs the `ChunkRotationClient` seam, call sites unchanged). Keep it a separate commit from all logic changes so the fix diff is readable.
- **Orphan `startTime` is best-effort** (WAV creation date). If the device test shows drift, record per-chunk start in `session.json` at rotation — only if needed.
