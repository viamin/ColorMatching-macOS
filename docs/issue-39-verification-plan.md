# Issue #39 verification plan

| Criterion | Smallest credible verification | Phase status |
| --- | --- | --- |
| Generated `/api/v1` client preserves the adapter contract | `PaletteAPIClientTests.testFetchColorsUsesProfileScopedOperationAndDecodesProfileEnvelope` checks the profile-scoped operation, authentication-covered adapter, and response envelope. The implementation phase must run this test after replacing the transport. | Added in test phase |
| Per-server/profile disk cache and offline-stale behavior remain unchanged | Existing `ProfileColorCacheTests` are the focused cache contract suite; the implementation phase must run it and the app-level catalog checks on macOS, where `ColorCatalog` is compiled. | Existing coverage; execution pending |
| Solver agrees with the committed server corpus | `SolverParityCorpusTests.testWeightedSquaredErrorMatchesParityCorpus` replays every v1 vector, including candidate scores, exclusions, selections, errors, and tie evidence. | Added in test phase |
| Corpus consumption is documented | `docs/solver-parity-corpus.md` records the source and exact refresh procedure. The implementation phase must add the same reference to the root README. | Added in test phase |
| PR reports generated-client migration and parity findings | Inspect the PR description against the implementation diff and test output. This requires human/repository evidence, not a unit test. | Pending implementation PR |
