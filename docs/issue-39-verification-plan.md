# Issue #39 verification plan

| Criterion | Smallest credible verification | Status in this tests-only run |
| --- | --- | --- |
| Typed OpenAPI client replaces handwritten endpoint wiring | Focused mocked transport tests assert the generated client's profile and color operations preserve `/api/v1` request shape and decoded DTO mapping. | Not yet runnable: generated client and upstream OpenAPI document are not present. |
| Per-server/profile disk cache remains intact | Existing `ProfileColorCacheTests` exercise server/profile namespace isolation and disk round trips. | Covered by permanent unit tests. |
| Offline-stale badge and cached profile fallback remain intact | UI-model integration test with a failing API transport and a populated cache. | Requires implementation-run test seam; no database or live server required. |
| Solver matches the committed parity corpus, including ties | `SolverParityCorpusTests` loads the committed corpus and asserts selected IDs and exclusions for every case. | Covered by permanent unit test. |
| Corpus consumption is documented | README describes the checked-in corpus location and an authenticated refresh command/review procedure. | Deferred: README is outside this tests-only phase allowlist. |
| PR documents migration, API shape differences, and parity result | Inspectable PR description based on the generated output and the upstream corpus revision. | External/human evidence; deferred until dependencies are accessible. |

The upstream issue references are `viamin/color_matching#110` (OpenAPI) and
`viamin/color_matching#111` (solver corpus). This environment received a 404
when querying the latter without repository credentials on 2026-11-05. The
fixture is deliberately isolated under the test target so implementation can
replace it with the exact upstream artifact once it is available.
