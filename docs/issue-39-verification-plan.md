# Issue #39 verification plan

| Criterion | Smallest credible evidence | Phase |
| --- | --- | --- |
| Generated OpenAPI client is adopted by `ColorComposerCore` | `GeneratedClientAdoptionTests.testPackageDeclaresOpenAPIClientDependenciesAndGeneratedSource` verifies manifest dependencies and a clearly named generated-source location; implementation review verifies `PaletteAPIClient` routes its two requests through it. | Red test now; implementation and review next |
| Existing `/api/v1` behavior remains compatible | Existing `PaletteAPIClientTests` cover profile and color request decoding/auth. The implementation run must add or update focused tests for any published-spec envelope changes. | Implementation |
| Cache, offline-stale badge, and cached-profile fallback remain intact | `ProfileColorCacheTests` cover disk cache isolation and fallback. The implementation run must run them and inspect `ColorCatalog`’s offline-stale UI state. | Implementation + human inspection |
| Solver selections match the backend corpus | `WeightedSquaredErrorParityTests.testSelectionsMatchCommittedParityCorpus` is the permanent loader for `Fixtures/weighted_squared_error_parity_corpus.json`, including ties, exclusions, and weights. | Red test now; vendoring required next |
| README explains corpus refresh | Inspect the README after adding the upstream corpus path and refresh procedure. | Implementation review |
| PR records migration, API shape findings, and parity results | Inspect the PR description against the issue checklist. | Human/external evidence |

PR #111 was not accessible from this environment during the red phase, so its corpus is intentionally not fabricated. The test expects its committed fixture at `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity_corpus.json`. The implementation run must copy the upstream corpus verbatim and retain `schema_version`, repository, pull request, and path metadata. Refresh by replacing that fixture with the upstream corpus and running the parity test. If PR #111 changes its on-disk path or JSON schema, update this loader and this plan in the same change.
