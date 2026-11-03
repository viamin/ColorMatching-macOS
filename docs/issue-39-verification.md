# Issue #39 verification plan

This test-writing change establishes the permanent regression harness for the
solver contract. The canonical corpus is owned by
[`viamin/color_matching#111`](https://github.com/viamin/color_matching/pull/111).
The fixture currently records the contract cases needed to exercise this client
while that private dependency is unavailable to the agent environment.

When #111 is available, replace
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`
verbatim with its committed corpus (retaining its upstream revision/source
metadata), then run the dedicated parity test target described below.

| Acceptance criterion | Smallest credible verification | Status in this test-writing change |
| --- | --- | --- |
| Typed generated `/api/v1` client replaces handwritten decoding | Focused `PaletteAPIClient` contract tests using generated-client operations, plus an inspectable generated source/spec artifact | Deferred: implementation files and package manifest are outside this run's allowlist. |
| Per-server/profile cache, offline-stale badge, cached-profile fallback are unchanged | Existing `ProfileColorCacheTests` plus a focused catalog-level fallback test | Existing cache tests are retained; catalog integration test is deferred because app sources are outside this package test target. |
| Solver selection matches parity corpus, including ties | `SolverParityCorpusTests.testWeightedSquaredErrorSelectionsMatchParityCorpus` loads a committed JSON corpus and asserts selected palette ID, exact score, and exclusions | Added. It covers nearest selection, earliest tie, exclusion, zero-weight channels, weights, and unmatched cells. |
| Corpus consumption is documented | README records upstream corpus location and a refresh command/process | Deferred: README is not in the documentation allowlist for this test-writing run. |
| PR records migration/parity findings | PR description cites the generated source/spec revision and the full parity test result | Deferred until the upstream corpus and OpenAPI PR are accessible. |

## Implementation handoff

The implementation run must add a dedicated `SolverParityTests` SwiftPM test
target and make this fixture a declared test resource (rather than relying on
`#filePath`). It must also replace this provisional fixture with the canonical
corpus from #111, add `swift-openapi-generator` and `swift-openapi-runtime`,
and update the root README's **Palette data** section with the corpus refresh
steps.

The agent environment has no Swift toolchain and the GitHub proxy rejected an
unauthenticated request for the private dependency; neither a test name nor a
green broad suite is treated as evidence for those external criteria.
