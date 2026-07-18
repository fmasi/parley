# Task 8 Report — crash-restart naming collision (data loss, #135)

## RED evidence

Added 5 `@Test`s to the existing `CrashRecoveryPlannerTests` struct in
`SwiftTests/TranscriberTests/CrashRecoveryPlannerTests.swift`, driving
`CrashRecoveryPlanner.nextFreeChunkIndex(outputDirectory:sessionId:)` before it existed. Filtered
run failed at **compile time** (expected):

```
CrashRecoveryPlannerTests.swift:81:38: error: type 'CrashRecoveryPlanner' has no member 'nextFreeChunkIndex'
(x5, one per new test)
```

## Spec discrepancy caught during TDD (test 5)

The task's formula is explicit: `nextFreeChunkIndex = 1 + max(index over (session.json completed
indices ∪ on-disk <sessionId>-N.wav indices))`. Test 5
(`nextFreeIndexAvoidsCollisionWithCompletedIndex`) was specified with `chunkIndices: [0,1,2]` +
`m-2.wav` (a collision file — WAV named after an already-completed index) → expected `== 4`.
Plugging those exact inputs into the stated formula gives `union = {0,1,2}`, `max = 2`, result
`= 3`, not 4 — the `4` in the task text appears to be a copy-paste artifact shared with tests 1 and
4 (both of which use a *different* on-disk file, `m-3.wav`, for which 4 is correct). I trusted the
explicit formula over the one inconsistent expected value, corrected the test to assert `3`, and
added a comment explaining why: 3 still satisfies the test's actual invariant ("avoids collision" —
3 doesn't match any index already in use: 0, 1, or 2). Confirmed this is not a masked implementation
bug: manually re-derived the formula against all 5 cases before changing the assertion, and the
other 4 tests continue to match the spec exactly with no changes.

## Implementation (`TranscriberCore/CrashRecoveryPlanner.swift`)

Factored a shared private `onDiskChunkIndices(outputDirectory:sessionId:)` scan out of the existing
`orphanChunks` (identical `<sessionId>-N.wav` parsing, minus the completed-index filter) and used it
in both `orphanChunks` and the new `nextFreeChunkIndex`, per the task's "reuse the same directory
scan" instruction. `nextFreeChunkIndex` unions `SessionState.read(...)?.chunks.map(\.index)` with
the on-disk scan's indices and returns `(max ?? -1) + 1`.

## Deliverable B — the three restart sites

All three were exactly where the task said, confirmed by reading each in full context first:

1. **`TranscriberApp/TranscriberApp.swift` ~292-293`** — `recoverIfNeeded`'s Flow B (legacy,
   non-chunked) restart, inside `if sysSize > 44`.
2. **`TranscriberApp/TranscriberApp.swift` ~351-352`** — `setupCrashHandler`'s
   `captureClient.onServiceCrash` closure (the critical one: this is what fires on a live XPC
   crash with no rotator, e.g. after an app relaunch re-attached via Flow A).
3. **`TranscriberApp/Views/MenuView.swift` ~620-621`** — `handleXPCCrash`'s `else` branch (no
   `chunkRotator`/`chunkProcessor` — i.e. no live pipeline in this process).

At each site, replaced `segmentBaseName(originalPath: sentinel.systemAudioPath, segment: sentinel.segment + 1)`
with:

```swift
let sessionId = stripSegmentSuffix(sentinel.systemAudioPath)
let idx = max(
    CrashRecoveryPlanner.nextFreeChunkIndex(outputDirectory: outputDir, sessionId: sessionId),
    sentinel.chunkIndex + 1
)
let baseName = "\(sessionId)-\(idx)"
```

`sentinel.chunkIndex + 1` is a defensive floor for a corrupt/unreadable `session.json` (each site
carries a comment explaining this). The sentinel's `segment: segment + 1` bookkeeping is untouched
(`sentinel.incrementedSegment(...)` is still called the same way) — site 1's `seg` local is still
used for its `recordLaunchRecovery` log tag, so it's kept; sites 2 and 3 no longer needed a local
`seg` var for naming and I dropped it there (it wasn't used elsewhere in either closure — verified
by grep before removing). MenuView's `sentinel.segment > 1` legacy single-file trigger and
`SegmentDiscovery`'s gap-tolerant 0-indexed scan (which enumerates *all* `<root>-N.wav` on disk
regardless of contiguity, per its own doc comment) are unaffected: they don't depend on restart
files being sequentially numbered, so a restart landing on a higher, non-contiguous chunk index is
still discovered and stitched correctly.

Traced how `idx` reaches disk to rule out a hidden rename/rotation I might have missed:
`AudioCaptureService.startCapture` builds `sysPath`/`micFilePath` as
`outputDirectory/<baseName>.wav` / `<baseName>_mic.wav` with no further transformation — confirmed
no interaction the investigation missed, so no `BLOCKED`.

## Deliverable C — done (not deferred)

Wired `recoverIfNeeded`'s chunked-recovery success branch (`TranscriberApp.swift`, right after
`ChunkedSessionRecovery.recover` returns a non-nil result) to call
`RenameWindowController.shared.show(jsonPath:onDismiss:)` with `MenuView.autoSummarize(jsonPath:config:)`
in the completion — the exact pair `MenuView.stopRecording`'s success branch already uses. Both are
plain `static`/singleton members of the same target (`RenameWindowController.shared` is a
`@MainActor final class` singleton; `MenuView.autoSummarize` is a self-free `static func`), and
`recoverIfNeeded` is already `@MainActor`, so no refactor was needed — just captured
`result.jsonPath` into a local `recoveredJsonPath` so the show-dialog call could sit after the
shared `RecordingSentinel.delete()` / `appState.phase = .idle` lines (mirroring the stop path's
phase-then-show ordering) without duplicating that teardown per-branch.

## Verify

- `swift build`: clean (`ok (build complete)`), no new warnings introduced.
- Full suite (`--filter TranscriberTests`, full flag set): **773 tests in 85 suites, all passed**
  (5 new `CrashRecoveryPlannerTests` cases; 0 regressions).

## Concerns for final review

- Deliverable B is app-wiring only, no unit test per the task's own scope (device-tested). The pure
  `nextFreeChunkIndex` helper it depends on is fully unit-tested; the wiring itself should get a
  real crash-recovery device test alongside the rest of the #135 branch.
- `segmentBaseName`/`SegmentNaming.swift` is now unused by app code (only its own unit tests call
  it) — left in place since removing it wasn't in scope for this data-loss fix and it's still a
  clean, independently-tested pure function; flagging as a possible follow-up cleanup, not doing it
  here to avoid scope creep on a fix explicitly framed as "be careful."
