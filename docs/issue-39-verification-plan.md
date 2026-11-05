# Issue #39 verification plan

| Acceptance criterion | Smallest credible verification | Evidence location |
| --- | --- | --- |
| Typed generated client migrates palette requests | Focused API-client contract tests for both endpoints, plus source inspection of the generated-client wrapper | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift`; implementation PR review |
| Per-server/profile cache and offline fallback are unchanged | Existing focused cache tests plus manual app inspection for the offline-stale badge | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift`; app review |
| Solver agrees with the backend corpus | Permanent unit test replays every committed v1 golden vector, candidate score, selection, and tie case | `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityTests.swift` |
| README explains corpus consumption | Documentation inspection | `README.md` |
| PR records migration notes and parity results | Pull-request description review | PR body |

The parity corpus is a permanent regression test because the scorer contract is
shared with the backend and affects every generated composition. No system test
is appropriate for the generated-client migration: the important recurring
behavior is the focused API contract, while the cache UI and its badge require
inspectable app-level evidence.
