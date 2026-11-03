# Issue #39 verification plan

This test-writing change records the smallest credible verification for each
acceptance criterion before the generated-client implementation begins.

| Criterion | Verification | Current result |
| --- | --- | --- |
| Generated OpenAPI client backs `PaletteAPIClient` while preserving `/api/v1` requests | Permanent `PaletteAPIClientTests` contract tests for request path, query, authorization, decoding, and error mapping. The implementation run must add generated-client package/generator integration and update these tests if the published spec changes the DTO shapes. | Not run in this test-writing phase. |
| Per-server/profile disk cache, offline-stale state, and cached-profile fallback are unchanged | Existing permanent `ProfileColorCacheTests` covers server/profile namespacing and cache round-trips. The implementation run must run the app-level fallback tests or record a manual UI check for the offline badge and cached-profile picker, because those state transitions live in `ColorCatalog`. | Not run in this test-writing phase. |
| Solver selections exactly match the committed server corpus, including ties | Permanent `SolverParityCorpusTests.testWeightedSquaredErrorSelectionMatchesCommittedParityCorpus`, replaying `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/color_matching_solver_parity_v1.json`. | Not run in this test-writing phase. |
| README explains corpus origin and refresh | Human review of the README change. The implementation run must document source `viamin/color_matching/priv/parity/v1/corpus.json`, pin/ref strategy, and refresh command. | Not applicable until implementation/documentation phase. |
| PR description records generated-client migration, API shape findings, and parity findings | Inspectable PR description. | Not applicable: this run may not open or push a PR. |

## Corpus provenance and refresh contract

The committed fixture was obtained from `viamin/color_matching` issue #111 at
`priv/parity/v1/corpus.json`, with `algorithm_version: 1`. Refresh only from a
reviewed upstream commit, preserve the upstream bytes, and run the parity test
before committing the replacement. A corpus algorithm-version increase requires
explicit review of solver compatibility rather than a blind fixture update.
