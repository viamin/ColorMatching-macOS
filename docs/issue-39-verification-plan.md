# Issue #39 verification plan

| Criterion | Smallest credible verification | Status in this tests-only change |
| --- | --- | --- |
| Generated OpenAPI client replaces/wraps API client | `GeneratedOpenAPIClientContractTests` checks the package declares the generator, runtime, and generator plugin; implementation must add generated-client request tests. | Red |
| Per-server/profile disk cache, offline-stale state, cached-profile fallback persist | Existing `ProfileColorCacheTests` cover server/profile cache isolation and cache round trips. The app-level fallback/badge is human-visible and requires an implementation-run integration check. | Existing coverage / not run here |
| Solver parity corpus selection, ties, exclusions, and weights | `SolverParityCorpusTests` replays the committed v1 corpus through `WeightedSquaredErrorScorer` and `CompositionSolver`. | Green |
| Corpus consumption documented | Implementation run must add the refresh instructions to the README. | Not run here |

The corpus fixture is copied verbatim from `viamin/color_matching` at `priv/parity/v1/corpus.json`. Refresh it after the backend changes the corpus by copying that committed upstream file to `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity_v1.json`, reviewing its `algorithm_version`, then running `cd ColorComposerCore && swift test`.
