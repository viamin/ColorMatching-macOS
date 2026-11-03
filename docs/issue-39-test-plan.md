# Issue #39 verification plan

| Criterion | Smallest credible verification | Phase status |
| --- | --- | --- |
| Generated OpenAPI client preserves palette/profile requests and authentication behavior | Focused `PaletteAPIClient` service tests using a URL protocol to assert the public request and decoded response contract. | Existing coverage; implementation run will add generated-client-specific regression cases if the adapter boundary changes. |
| Per-server/profile cache, offline-stale badges, and cached-profile fallback remain intact | Focused `ProfileColorCache` and `ColorCatalog` tests for cache-key isolation and network-failure fallback; human inspection of the app badge remains required. | Existing coverage to be re-run in implementation phase. |
| Solver exactly matches the backend corpus, including ties | Permanent corpus-driven `WeightedSquaredErrorParityTests` validates every candidate score and one-cell solver selection from the committed v1 corpus. | Added in this test-writing run; currently red until the committed fixture is supplied. |
| README explains corpus source and refresh | README review against the committed fixture path and upstream source. | Deferred: README is outside the tests-only allowlist. |
| PR records migration and parity findings | PR description review; this is GitHub-visible human/external evidence. | Not run in the tests-only phase. |
