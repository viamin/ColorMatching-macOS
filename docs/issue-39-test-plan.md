# Issue #39 test plan

| Criterion | Smallest credible verification | Phase |
| --- | --- | --- |
| Generated OpenAPI client backs palette/profile requests | Focused mocked-client tests for the generated operation boundary and its request shape | Implementation |
| Cache remains scoped by server and profile | Existing `ProfileColorCacheTests` plus a focused catalog fallback test that verifies stale/offline state | Implementation |
| Solver remains in backend parity | `SolverParityCorpusTests` replays every committed `parity-v1-corpus.json` scenario and checks scores, exclusions, selection, errors, and ties | This PR |
| Corpus refresh is documented | README documents the upstream source, pinned path, and refresh procedure | Implementation (README is outside this test-writing phase allowlist) |
| Generated-client migration and API shape findings recorded | PR description with generated source/spec revision and test results | Implementation / human review |

The solver corpus is a permanent focused unit test because parity is a recurring contract. Offline fallback is also recurring behavior; it needs a permanent focused test at the catalog boundary rather than relying on a broad suite.
