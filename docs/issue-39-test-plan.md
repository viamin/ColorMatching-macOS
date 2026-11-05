# Issue 39 verification plan

This tests-only change establishes the acceptance checks that the implementation
change must satisfy.

| Criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Generated OpenAPI client replaces the hand-written API contract | Build `ColorComposerCore` with the generated client and exercise `/api/v1/printer_profiles` and `/api/v1/colors` through the existing `URLProtocol` seam. | Blocked on implementation-only package/source changes. |
| Per-server/profile disk cache, offline-stale indication, and cached-profile fallback remain intact | Existing `ProfileColorCacheTests` plus `ColorCatalog` integration coverage; implementation run must execute the focused tests after migrating the transport. | Not run in this tests-only phase. |
| Solver selections preserve server parity | `SolverParityCorpusTests.testWeightedSquaredErrorMatchesParityCorpus`, replaying every committed v1 vector, asserts scores, exclusions, errors, and earliest-wins selection. | Red until the upstream corpus is committed at the fixture path. |
| Corpus consumption is documented | README links the committed fixture to upstream `viamin/color_matching#111` and explains the reviewed refresh command/source. | Blocked: README is outside the tests/LID allowlist for this phase. |
| Test suite is green | `swift test` after fixture, generated client, and migration land. | Not run: the new red test deliberately has no fixture yet. |
