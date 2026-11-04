# Issue #39 verification plan

This tests-only change establishes the acceptance-criterion evidence that the
implementation follow-up must satisfy.

| Criterion | Smallest credible verification | Evidence at this revision |
| --- | --- | --- |
| Typed generated client replaces `/api/v1` hand decoding | Focused `PaletteAPIClient` tests assert generated-operation requests and response mapping, including API-shape changes | Not yet implemented; no generated client exists in this tests-only phase. |
| Cache and offline behavior remains unchanged | Existing cache unit tests plus focused client integration tests cover server/profile scoping, stale fallback, and cached profiles | Existing `ProfileColorCacheTests`; migration-specific tests still required. |
| Solver matches backend corpus | Permanent unit test decodes the committed backend corpus and verifies each candidate score, selection, error, exclusions, and ties | `SolverParityTests.testWeightedSquaredErrorMatchesCommittedV1ParityCorpus` and its v1 fixture. |
| Corpus use is documented | README points to the local fixture, upstream source, and refresh procedure | Deferred: the test-writing phase permits only test paths and `docs/`; add this in the implementation phase. |
| PR records migration and parity findings | PR body cites the test output, generated-client shape review, and parity cases | Human/PR evidence required after implementation; not applicable to this tests-only revision. |

The parity fixture is copied from `viamin/color_matching` issue #111 at commit
`47057afd58f7d46b4d4b740ca7d2d08947774471`, path
`priv/parity/v1/corpus.json` (blob `70e9999065c81334d1f2b5038a96c67cfd5d59d1`).
