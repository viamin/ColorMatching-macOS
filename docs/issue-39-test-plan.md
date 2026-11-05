# Issue #39 verification plan

This test-writing change maps every acceptance criterion to its smallest credible verification before implementation begins.

| Criterion | Verification | Evidence at this revision |
| --- | --- | --- |
| Generated OpenAPI client replaces the hand-written `/api/v1` transport without changing consumed operations | Focused API-client contract tests; implementation review of `Package.swift` and generated source | Existing `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift`; implementation not yet present in the test-writing phase |
| Disk cache remains scoped by server/profile and offline data remains visibly stale; cached profiles remain a fallback | Permanent unit/service tests for cache scoping and app-level fallback; manual UI verification for the stale badge | Existing `ProfileColorCacheTests.swift`; no app-shell fallback test target currently exists, so the implementation run must add it or record inspectable manual evidence |
| Solver selections exactly match the committed parity corpus, including ties, exclusions, and weight handling | Permanent corpus-driven solver test | `WeightedSquaredErrorParityCorpusTests.swift` and `Fixtures/weighted_squared_error_parity_corpus.json` |
| README explains the corpus location and refresh procedure | Inspectable documentation review | Deferred: this phase allows only `docs/` and test paths; update `README.md` in the implementation run |
| PR records migration notes, API shape changes, and parity results | PR description review | Deferred until a PR exists; record exact upstream corpus revision, tie/exclusion/weight results, and any OpenAPI incompatibilities |

## External dependency note

The fixture declares `viamin/color_matching#111` as its source. The upstream pull-request ref was not accessible from this test environment, so the implementation run must replace or confirm this fixture against the exact upstream committed artifact and record its source path and revision in the PR description before merge.
