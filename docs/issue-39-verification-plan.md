# Issue #39 verification plan

| Criterion | Smallest credible verification | Status in test-writing phase |
| --- | --- | --- |
| Generated OpenAPI client replaces the handwritten `/api/v1` transport while retaining behavior | Focused `PaletteAPIClient` request/response tests against the generated transport seam, including authorization and current endpoint shapes | Pending implementation test additions |
| Per-server/profile cache, offline-stale indicators, and cached-profile fallback remain intact | Existing `ProfileColorCacheTests` plus a focused `ColorCatalog` service test with a transport failure and an already-cached profile | Pending implementation test additions |
| Solver agrees with the upstream parity corpus, including ties | Permanent `WeightedSquaredErrorParityTests.testMatchesVersionOneCorpusExactly`, replaying committed `solver-parity-v1.json` | Red: fixture intentionally absent until copied from `viamin/color_matching/priv/parity/v1/corpus.json` |
| README explains corpus location and refresh procedure | Human inspection of the README change against the upstream corpus location | Pending implementation; README is outside this test-writing phase's allowed paths |
| PR records migration details, API shape findings, and parity results | Inspectable PR description | Not run; no PR is opened in this run |
