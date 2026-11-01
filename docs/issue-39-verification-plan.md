# Issue #39 verification plan

This tests-only change establishes the persistent verification contract before
the generated-client implementation lands.

| Criterion | Smallest credible verification | Status in this run |
| --- | --- | --- |
| Typed OpenAPI client replaces hand-written API decoding while preserving request behavior | Focused `PaletteAPIClientTests` covering the generated client's `/api/v1` operations, authorization, and decoded profile/color payloads | Planned for implementation run; current hand-written client remains in place |
| Per-server/profile cache and offline-stale/profile fallback remain unchanged | Existing persistent unit tests in `ProfileColorCacheTests` plus an app-model service test of a failed network fetch served from cache | Cache unit coverage exists; fallback integration coverage is planned for implementation run |
| Solver agrees with the upstream parity corpus, including ties | `WeightedSquaredErrorParityTests.testParityCorpusMatchesScoresSelectionsAndTieBreaks`, replaying every committed v1 scenario through both scorer and solver | Added in this run |
| Corpus consumption is documented, including refresh source | README points to `viamin/color_matching` `priv/parity/v1/corpus.json`, pins its source revision, and gives an explicit refresh command | Planned for implementation run; README is outside the test-writing allowlist |
| PR records migration/API-shape/parity findings | PR body includes generated-client notes, API shape delta, and the exact parity run result | External/GitHub evidence; no PR is opened in this run |

The committed fixture is copied verbatim from
`https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json`
(blob `70e9999065c81334d1f2b5038a96c67cfd5d59d1`). It deliberately exercises
tie ordering, missing positive-weight measurements, zero weights, single-channel
matching, exact zero errors, and unknown server weight keys.
