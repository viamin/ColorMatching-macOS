# Issue #39 acceptance plan

This is the tests-only phase for issue #39. The implementation phase must
preserve these checks and add the generated OpenAPI client; it must not change
the solver's selection semantics to satisfy a fixture.

| Criterion | Smallest credible verification | Phase |
| --- | --- | --- |
| Typed OpenAPI client replaces or wraps `PaletteAPIClient` | Focused mocked-transport tests assert the generated operation paths, query, auth header, decoding, and conversion to the existing DTOs. | Implementation |
| Disk cache, offline-stale badge, and cached-profile fallback remain intact | Existing `ProfileColorCacheTests` plus a focused `ColorCatalog` integration test driven by a failing transport and a populated cache. | Implementation |
| Solver selections remain server-compatible | `SolverParityCorpusTests.testWeightedSquaredErrorSelectionsMatchParityCorpus` loads the committed JSON corpus and asserts the selected candidate ID for every case. | This phase |
| Ties, exclusions, and zero/positive weight handling | Corpus cases `equal-score-tie-keeps-earliest-candidate`, `missing-active-response-is-excluded`, `all-missing-active-response-is-unmatched`, and `zero-weight-response-is-not-required`. | This phase |
| README explains corpus location and refresh process | Human inspection of the README section added alongside importing the upstream artifact. | Implementation |
| PR records generated-client migration, API shape findings, and parity result | Human inspection of the PR description using the implementation test run output. | Implementation |

## Parity corpus consumption

The executable test reads
`ColorComposerCore/Tests/ColorComposerCoreTests/Resources/weighted_squared_error_parity.json`.
It treats the corpus as data: each case supplies palette responses, target
responses, channel weights, and an expected selected candidate ID (or `null`
when every candidate is excluded).

The upstream corpus for this issue is owned by
[`viamin/color_matching#111`](https://github.com/viamin/color_matching/issues/111).
When that artifact is available to this checkout, replace the fixture contents
verbatim, update the schema adapter in `SolverParityCorpusTests` if its field
names differ, and run `cd ColorComposerCore && swift test --filter
SolverParityCorpusTests`. The implementation-phase README update should point
to this path and repeat that refresh command.

The initial fixture is deliberately limited to the currently documented server
contract cases because the referenced upstream repository/PR is not accessible
from this environment. It must be replaced with the committed upstream corpus
before issue #39 is considered complete.
