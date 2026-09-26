Review the PR for Parley (a macOS menu-bar meeting
transcriber written in Swift: SwiftUI app + XPC audio-capture service
+ TranscriberCore logic library). Be concise and high-signal — only
flag things that matter. Focus on:
- Correctness bugs, edge cases, and broken error handling, especially
  around audio formats, file I/O, XPC lifecycle, and concurrency
  (actor isolation, @MainActor, data races).
- Test coverage: per the repo's TDD rule, new or changed logic should
  have Swift Testing unit tests (SwiftTests/TranscriberTests/) covering
  happy path, edge cases, and invalid inputs. Flag untested new behaviour.
- Security and privacy: leaked secrets/keys, audio/transcript paths or
  speaker names logged as .public, unsafe deserialization.
- Clarity and consistency with surrounding code and the architecture
  described in CLAUDE.md.
- Whether behaviour changes are reflected in docs (CLAUDE.md, docs/,
  scripts/test-checklist.md).

Do not approve or block; just review.
