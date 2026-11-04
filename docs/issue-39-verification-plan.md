# Issue #39 verification plan

This test-writing change records the smallest credible verification for each
acceptance criterion. The implementation run must replace the locally staged
corpus with the exact committed artifact from `viamin/color_matching#111` and
record its source revision in the fixture before reporting parity as passed.

| Criterion | Verification | Current status |
| --- | --- | --- |
| Generated OpenAPI client powers `PaletteAPIClient` | Focused API client request/response tests, plus inspect generated source and package dependency at PR head | Not run: implementation is out of scope for this test-writing run |
| Server/profile cache, offline-stale state, and cached profile fallback remain intact | Existing focused `ProfileColorCacheTests`; implementation run must add or run `ColorCatalog` integration coverage for UI stale badges and profile fallback | Not run: app integration target is not runnable in this container |
| Solver selections match the parity corpus, including ties | Permanent `WeightedSquaredErrorParityCorpusTests` loads its committed JSON fixture and compares selected palette IDs exactly | Blocked on exact upstream corpus artifact from `viamin/color_matching#111` |
| README says where the corpus lives and how to refresh it | Human inspection of the README diff | Deferred: README is outside the test-writing allowlist |
| PR description records migration, API-shape, and parity findings | Human inspection of PR description against implementation evidence | Deferred: no PR is opened in this run |

The solver fixture intentionally covers weighted selection, ignored zero-weight
channels, exclusion for a missing active measurement, and first-in-palette tie
selection. It is a harness placeholder, not a claim that the unavailable
upstream corpus revision has been imported.
