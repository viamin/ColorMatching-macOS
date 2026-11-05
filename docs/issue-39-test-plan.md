# Issue #39 acceptance verification plan

| Criterion | Smallest credible verification | Phase |
| --- | --- | --- |
| Generated OpenAPI client replaces hand-written endpoint decoding | Focused `PaletteAPIClient` request/response tests using a generated-client transport seam, including the two endpoints and authorization. | Implementation |
| Disk cache and offline fallback are unchanged | Existing `ProfileColorCacheTests` extended with a client-backed cache miss, stale-color fallback, and cached-profile fallback scenario. | Implementation |
| Solver mirrors the server | `SolverParityCorpusTests` replays every case in `Fixtures/solver-parity-v1.json`, asserting each candidate score plus solver selection/error. | This PR |
| Tie cases, exclusions, and weights remain exact | The same parity test asserts server-produced scores and earliest selected index for every fixture, including all-excluded cases. | This PR |
| Corpus consumption is documented | README links to the corpus source and states a SHA-pinned refresh procedure. | Implementation |
| Migration notes and parity results are in the PR | Human review of the PR body, based on generated-client output and the parity test run. | Implementation / human |

The parity fixture is deliberately a test resource, not a hand-authored test
matrix. Its upstream authority is
`viamin/color_matching@a82aec5441d2a7b0100e8c8ab81d573e11ace9b0`,
`priv/parity/v1/corpus.json`.
