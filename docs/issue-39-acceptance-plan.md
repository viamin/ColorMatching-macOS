# Issue #39 acceptance verification plan

| Criterion | Smallest credible verification | Status in this test-writing PR |
| --- | --- | --- |
| Generated OpenAPI client replaces or wraps `PaletteAPIClient` | Focused package-configuration regression test; implementation PR will add generated-client request/response tests against the published OpenAPI document. | Red: `GeneratedOpenAPIClientConfigurationTests.testCorePackageDeclaresGeneratedOpenAPIClientDependencies` |
| Per-server/profile cache, offline-stale badge, and cached-profile fallback stay intact | Existing focused cache tests plus a future app-level test if the client seam changes. | Covered by `ProfileColorCacheTests`; no new behavior is required in this red phase. |
| Solver selections match the published corpus, including ties | Permanent corpus replay test through `WeightedSquaredErrorScorer` and `CompositionSolver`. | Covered by `WeightedSquaredErrorParityCorpusTests.testPublishedV1CorpusMatchesScorerAndSolverSelections` |
| Corpus consumption is documented and refreshable | Inspect the README instructions added by the implementation PR. | Not yet implemented; requires a README edit outside this test-writing scope. |
| PR records migration notes, API shape findings, and parity results | Inspect the implementation PR description. | Human/external evidence required at PR creation. |

The parity fixture is the committed v1 corpus published by `viamin/color_matching` issue #111. It deliberately covers strict winners, two- and three-way ties, missing candidate and target measurements, zero-weight channels, unknown weights, and all-excluded selections.
