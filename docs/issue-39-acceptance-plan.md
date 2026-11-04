# Issue #39 acceptance plan

This tests-only change establishes the verification seam before the generated-client implementation begins.

| Criterion | Smallest credible verification | Current artifact/status |
| --- | --- | --- |
| Typed OpenAPI client replaces handwritten `/api/v1` transport | Inspect generated sources and `Package.swift`; focused mocked-transport API tests verify the two consumed operations and their request paths | Pending implementation; a test cannot prove which internal client produced a behavior-equivalent request. |
| Cache remains per server and printer profile | Focused unit tests for `ProfileColorCache` server/profile namespace isolation | Existing `ProfileColorCacheTests` covers this. |
| Offline-stale badge and cached-profile fallback remain available | Permanent app/system test through `ColorCatalog`/UI state using a failing transport and a seeded disk cache | Pending: this belongs to the app target and needs an injectable failing transport. |
| Solver selections match the backend parity corpus, including ties, exclusions, and weights | Permanent corpus-driven unit test that loads the committed fixture and resolves every fixture case through `CompositionSolver` + `WeightedSquaredErrorScorer` | `SolverParityCorpusTests` added. It is intentionally red until the authoritative `viamin/color_matching#111` corpus can be retrieved and committed. |
| README explains corpus refresh | Inspect README change and the committed corpus provenance | Pending implementation; this phase may only modify test and LID-document paths. |
| PR records migration notes, API shape differences, and parity results | Inspect PR description after implementation against generated OpenAPI output and the passing corpus run | Human/external evidence; pending implementation. |

## Upstream-artifact blocker

On 2026-11-04, unauthenticated requests for
`https://api.github.com/repos/viamin/color_matching/pulls/111` and its files endpoint returned HTTP 404 in this environment. The authoritative corpus therefore cannot be truthfully vendored during this tests-only run. The new test deliberately identifies the required fixture path:

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`

The implementation run must obtain that file from `viamin/color_matching#111`, preserve its provenance and format, and make this test green. Do not replace it with a locally invented corpus.
