# Issue #39 test plan

This test-writing change establishes the smallest durable verification for each
acceptance criterion before the generated-client implementation starts.

| Criterion | Verification | Current phase evidence |
| --- | --- | --- |
| Generated OpenAPI client sends the existing API requests correctly | Focused async client contract test | `PaletteAPIClientTests.testEndpointsUseAPIv1Shapes` records the current two endpoints, query key, headers, and response envelopes. The implementation phase must retain this behavior through the generated client. |
| Disk cache remains server/profile scoped | Focused unit test | Existing `ProfileColorCacheTests` covers profile cache round trips, separate server namespaces, and normalization. |
| Offline stale badge and cached-profile fallback remain unchanged | Human/external evidence plus app-level test in implementation phase | The behavior is owned by `ColorCatalog` in the app target; this Swift package test target cannot construct that private UI state. Implementation must add or retain app-target coverage, then verify the rendered offline state manually. |
| Solver selections exactly match the server | Permanent corpus replay | `SolverParityCorpusTests` replays server corpus v1, including score values, exclusions, no-selection scenarios, and earliest-index tie breaking. |
| Corpus refresh is documented | README update | Deferred: the test-writing restriction permits only `docs/`; implementation must add the refresh procedure to `README.md`. |

## Corpus provenance and refresh

The checked-in fixture at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`
is copied without transformation from
`viamin/color_matching` at
`priv/parity/v1/corpus.json` (algorithm version 1).

To refresh after the server intentionally changes solver semantics:

1. Update the server corpus using `mix parity.generate` and commit it there.
2. Copy the committed `priv/parity/v<N>/corpus.json` into this test fixture
   path (or its versioned successor).
3. Update the parity test's version expectation and run
   `swift test --package-path ColorComposerCore`.
4. Record the corpus version, exclusions, weights, and tie results in the PR.

The implementation phase must make this fixture a declared resource of its
dedicated solver-parity test target instead of relying on `#filePath`.

