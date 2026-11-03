# Issue #39 verification plan

This is the test-writing evidence for the generated OpenAPI-client and solver-parity migration.

| Criterion | Smallest credible verification | Status in test-writing run |
| --- | --- | --- |
| Generated client uses the published `/api/v1` profile-color operation | `PaletteAPIClientTests.testFetchColorsUsesProfileScopedOpenAPIEndpointAndDecodesProfileShape` checks the OpenAPI path, no legacy query, authentication, and the profile-scoped response body. | Red: current hand-written client requests the legacy path and cannot decode the profile-scoped color shape. |
| Per-server/profile disk cache, offline-stale badges, and cached-profile fallback remain intact | Existing `ProfileColorCacheTests` preserve the storage contract; implementation run must run the relevant cache/UI tests and inspect the fallback path. | Not rerun in this test-writing run. |
| Solver results match the committed parity corpus, including ties, exclusion, and weight handling | `SolverParityCorpusTests.testWeightedSquaredErrorMatchesParityCorpusExactly` replays every v1 scenario and asserts each score, earliest-wins selection, selected error, and tied index set exactly. | New permanent unit/service test. |
| Corpus consumption documented in README | Human-visible documentation update naming the upstream source and refresh procedure. | Deferred: `README.md` is outside the tests/LID-doc allowlist for this run. |
| PR description records migration/parity findings | PR body references the route change, generated-client adapter, and green parity replay. | Deferred to PR creation after implementation. |

The committed fixture is copied from `viamin/color_matching` at `priv/parity/v1/corpus.json` (algorithm version 1). Refresh it only by reviewing the upstream fixture revision; the next implementation run must make the README point to this file and state the refresh procedure.
