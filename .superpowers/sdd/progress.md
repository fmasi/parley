# #135 Crash-Recovery — Progress Ledger

Plan: docs/superpowers/plans/2026-07-18-crash-recovery-135.md
Branch: fix/crash-recovery-135 (worktree crash-recovery-135), base = origin/main 0ac51c2

- Task 1: relocate pipeline to Core (behavior-neutral) — DONE (see task-1-report.md)
- Task 2: CrashRecoveryPlanner (pure) — DONE (see task-2-report.md)
- Task 3: ChunkedSessionRecovery + real pipeline tests — pending
- Task 4: wire relaunch + stop — pending
- Task 5: run() offsets (H2) — pending
- Task 6: run() reconcile (H3) — pending
- Task 7: council + CI + device test — pending

## Results
Task 1: complete (commits f8b285e..910cc25, review clean; SPEC ✅ QUALITY approved).
  Minor (for final review): RunnerError + setDiarizer(_:) made public though not yet referenced by name (YAGNI). Behavior-neutral relocation, 750 tests pass.
Task 2: complete (pure `CrashRecoveryPlanner`, 5 tests, verified RED then GREEN; full suite 755 tests pass, +5 from baseline, 0 regressions).
