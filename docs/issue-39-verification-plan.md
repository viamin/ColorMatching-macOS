# Issue #39 verification plan

This test-writing change records the smallest inspectable verification for each acceptance criterion before the generated-client migration begins.

| Criterion | Verification | Evidence at implementation completion |
| --- | --- | --- |
| Typed OpenAPI client migrates `PaletteAPIClient` | Focused API-client contract tests for the two `/api/v1` operations, authorization, and error mapping | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift` plus a green `swift test` run |
| Disk cache and offline fallback remain unchanged | Permanent system-level app flow test that seeds a per-server/profile cache, makes the server unavailable, and verifies cached colors, stale state, and cached-profile selection | A `ColorMatchingTests` test and its result; existing `ProfileColorCacheTests` continue to cover cache isolation and persistence |
| Solver selection matches the upstream corpus | Permanent parity test replaying upstream scores, exclusions, selections, errors, and tie indices | `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift` and committed fixture |
| README tells maintainers how to refresh the corpus | Inspect the README text and verify its source URL, pinned local fixture location, upstream refresh command, and test command | README diff reviewed against `viamin/color_matching` `priv/parity/v1/corpus.json` |
| PR describes generated-client migration and parity findings | Human review of the PR body | PR body links the test result and records API shape changes, ties, exclusions, and weight handling |

The corpus is copied verbatim from `viamin/color_matching` commit `47057afd58f7d46b4d4b740ca7d2d08947774471`, path `priv/parity/v1/corpus.json`, SHA-256 `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`.
