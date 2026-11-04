# Issue 39 verification plan

This tests-only change establishes the regression contract before the generated-client implementation is introduced.

| Criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Typed OpenAPI client replaces hand-written `/api/v1` requests | Focused `PaletteAPIClient` request/response tests, expanded when the generated client is wired in | Existing coverage only; implementation phase required |
| Per-server/profile cache and offline fallback remain intact | Existing `ProfileColorCacheTests` cover namespacing and persisted profile entries; `ColorCatalog` fallback remains app-target integration work | Existing coverage only; implementation phase required |
| Solver matches the shared parity corpus, including ties | Permanent core test replays every committed v1 scenario, asserting per-candidate scores, selected index/hex/error, and `CompositionSolver` results when a target is representable as source grids | Added in this change |
| README explains corpus refresh | Inspect the README update and confirm it identifies upstream path and refresh command | Implementation phase required because this test-writing phase cannot edit the root README |
| PR records API shape and parity findings | PR body inspection | External evidence required at PR creation |

The committed fixture is copied verbatim from `viamin/color_matching` at `priv/parity/v1/corpus.json` (algorithm version 1). Refresh it by updating from that source after its `mix parity.generate` check passes, then run the core parity test.
