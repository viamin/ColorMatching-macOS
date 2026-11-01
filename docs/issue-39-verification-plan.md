# Issue 39 verification plan

| Criterion | Smallest credible evidence | Phase |
| --- | --- | --- |
| Generated OpenAPI client replaces the handwritten API transport while preserving the cache and offline fallback behavior | Focused `PaletteAPIClient` service tests for profiles, colors, stale colors, and cached-profile fallback, run after the generated-client migration | Implementation |
| Solver selections stay in parity with `color_matching` | Permanent `WeightedSquaredErrorParityCorpusTests` replaying the committed `priv/parity/v1/corpus.json` fixture, including candidate scores, exclusions, exact selections, and ties | This test-writing PR |
| Corpus refresh is maintainable | README records the upstream corpus location and a deliberate refresh command/review step | Implementation (README is outside this test-writing phase allowlist) |
| PR describes migration and parity findings | Inspectable PR body, including API shape observations and the corpus test result | Implementation PR |

The parity test is intentionally introduced before its fixture. It is red in this phase because `Fixtures/weighted_squared_error_v1.json` has not yet been committed. The implementation phase must copy the canonical corpus from `viamin/color_matching` at `priv/parity/v1/corpus.json` without changing its contents.
