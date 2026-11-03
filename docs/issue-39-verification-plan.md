# Issue #39 verification plan

| Criterion | Smallest credible verification | Status in test-writing run |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` | Focused `PaletteAPIClient` contract tests with a URL protocol, asserting generated-client request paths, authentication, and decoded profile/color responses | Deferred to implementation run; generated client does not exist yet |
| Server/profile cache and offline fallbacks remain unchanged | Existing permanent `ProfileColorCacheTests` plus a focused client/service test that induces transport failure after a cached profile fetch and asserts stale data/badge state | Existing disk cache coverage is present; stale-flow test deferred to implementation run |
| Solver agrees with server corpus | Permanent `SolverParityCorpusTests` replaying committed v1 vectors through `WeightedSquaredErrorScorer` and `CompositionSolver` | Added in this run |
| README describes corpus refresh | Inspectable documentation review against the upstream corpus URL and refresh command | Deferred: the test-writing boundary permits only `docs/`, not `README.md` |
| Suite and lint | `swift test` and configured lint command | Not runnable: Swift is not installed in this environment |

The fixture originates from `viamin/color_matching` issue #111 at
`priv/parity/v1/corpus.json` (blob `70e9999065c81334d1f2b5038a96c67cfd5d59d1`).
The scenario-count assertion intentionally stays red until the implementation
run replaces the initial coverage fixture with a byte-for-byte copy of the
authoritative corpus and adds the README refresh instructions.
