# #135 Crash-Recovery — Progress Ledger

Plan: docs/superpowers/plans/2026-07-18-crash-recovery-135.md
Branch: fix/crash-recovery-135 (worktree crash-recovery-135), base = origin/main 0ac51c2

- Task 1: relocate pipeline to Core (behavior-neutral) — DONE (see task-1-report.md)
- Task 2: CrashRecoveryPlanner (pure) — DONE (see task-2-report.md)
- Task 3: ChunkedSessionRecovery + real pipeline tests — DONE (see task-3-report.md)
- Task 4: wire relaunch + stop — DONE (see task-4-report.md)
- Task 5: run() offsets (H2) — pending
- Task 6: run() reconcile (H3) — pending
- Task 7: council + CI + device test — pending

## Results
Task 1: complete (commits f8b285e..910cc25, review clean; SPEC ✅ QUALITY approved).
  Minor (for final review): RunnerError + setDiarizer(_:) made public though not yet referenced by name (YAGNI). Behavior-neutral relocation, 750 tests pass.
Task 2: complete (pure `CrashRecoveryPlanner`, 5 tests, verified RED then GREEN; full suite 755 tests pass, +5 from baseline, 0 regressions).
Task 2: complete (commit 712459e, review clean; SPEC ✅ QUALITY approved). 755 tests. RED-first verified. Parsing proven robust vs adversarial sessionIds.
  Minor (for final review): isChunkedSessionRecoverable's "no session.json but orphan WAV present" branch not directly unit-tested (Task 3 exercises it via the flow).
Task 3: complete (see task-3-report.md). `ChunkedSessionRecovery.recover` implemented verbatim from the plan except one fixed compile-time discrepancy (return type is the top-level `TranscriptionResult`, not `TranscriptionRunner.TranscriptionResult` — no nesting/typealias exists). RED-first verified for the new type; real `ChunkRotatorTests`/`ChunkProcessorTests` recreated driving the actual classes (replacing the deleted characterization suites) with a shared `FakeEngine`/`FakeDiarizer`. Full suite: 762 tests, +7 from baseline, 0 regressions.
  Concern (for final review): the plan's given no-mic fallback (`micPath: sysURL.path` when no `_mic.wav` exists) makes `ChunkProcessor`'s `fileExists(chunk.micPath)` true — a system-only orphan chunk could be misclassified as dual-stream. Not exercised by the required tests (which supply both WAVs); flagged, not fixed, since it's the plan's exact specified code and a behavioral question, not a signature mismatch.
Task 3: complete (commits 062ef9b + fix fea67b7, review clean; SPEC ✅ QUALITY approved). 763 tests. Real pipeline tests via injected fakes.
  Bug caught+fixed by review: system-only orphan misclassified as dual-stream (RED-first fix fea67b7).
  Important (pre-existing, filed as follow-up issue, NOT a #135 blocker): mixed dual/single-stream chunk → un-reconciled speaker labels.
Task 4: complete (see task-4-report.md). App-level wiring only, no new unit test (needs real engines + capture — verified by Task 7's device test). Reused the exact engine/diarizer construction via one new `TranscriptionRunner.prepareEngine(config:)` factored out of `setupChunkedPipeline`'s inline logic (behavior-neutral extraction). `recoverIfNeeded` (Flow B) now checks `CrashRecoveryPlanner.isChunkedSessionRecoverable` before the stat-based single-file check and routes through `ChunkedSessionRecovery.recover`; `MenuView.stopRecording`'s no-live-pipeline fallback does the same before falling back to legacy `run()`. Full suite: 763 tests, 0 regressions (unchanged count — no unit-testable surface added by this task per the plan).
