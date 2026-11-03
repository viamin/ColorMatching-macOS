# Issue #39 verification plan

This tests-only change establishes the verification contract before the
generated-client migration is implemented.

| Criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Generated OpenAPI client is used by `PaletteAPIClient` | Inspect the package dependency, generated source, and request/response contract tests after implementation. | Not executable until the upstream OpenAPI document is available and implementation begins. |
| Per-server/profile disk cache, offline-stale state, and cached-profile fallback remain intact | Existing `ProfileColorCacheTests` cover server/profile isolation and disk round trips; the implementation run must add an injected failing transport integration test at the catalog boundary to verify offline fallback/badging. | Cache unit coverage exists; catalog-level fallback test pending. |
| Solver selections match the committed parity corpus | `SolverParityTests.testWeightedSquaredErrorSelectionsMatchParityCorpus` loads `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-parity.json` and compares selected color IDs. | Added. |
| README explains corpus location and refresh | Human inspection of the README after the implementation run. The test-writing guard allows `docs/` but not `README.md`. | Pending implementation phase. |
| PR records migration shape changes and parity findings | Human/external inspection of the PR description against the OpenAPI document and upstream corpus. | Pending implementation phase. |

## Corpus refresh

The test reads its committed JSON fixture directly, so it runs on every Swift
test invocation without network access. During implementation, replace this
seed fixture with the canonical corpus from
[`viamin/color_matching#111`](https://github.com/viamin/color_matching/pull/111),
preserving its cases verbatim and recording the upstream revision in the JSON
metadata. Keep tie, exclusion, and weight cases covered when refreshing.

The implementation run must also move this guidance into `README.md`, as
required by issue #39.
