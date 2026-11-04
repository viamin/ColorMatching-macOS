# Issue 39 verification plan

| Criterion | Smallest credible verification | Evidence status in tests-only phase |
| --- | --- | --- |
| Generated OpenAPI client is adopted | `OpenAPIClientAdoptionTests.testPackageDeclaresOpenAPIClientRuntimeAndGenerator` checks the package declaration. The implementation run must add behavioral request/response tests for the generated wrapper. | Intentionally red until implementation. |
| Per-server/profile cache and offline fallback remain intact | Existing `ProfileColorCacheTests` and `PaletteAPIClientTests` are the focused regression coverage. The implementation run must execute them after migrating the transport layer. | Pending execution (Swift toolchain unavailable in this container). |
| Solver agrees with the server corpus | `WeightedSquaredErrorParityTests.testV1CorpusMatchesSelectionsAndScores` replays the committed v1 corpus from `viamin/color_matching#111`, including score, selection, ties, and exclusions. Fixture source: `priv/parity/v1/corpus.json` at `47057afd58f7d46b4d4b740ca7d2d08947774471` (SHA-256 `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`). | Pending execution (Swift toolchain unavailable in this container). |
| README explains corpus refresh | Inspect the README change and the vendored fixture source/version during implementation review. | Deferred: this tests-only phase may only commit tests and LID documentation. |
