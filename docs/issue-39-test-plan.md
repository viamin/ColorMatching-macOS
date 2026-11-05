# Issue #39 test plan

This tests-only change maps each issue acceptance criterion to the smallest credible verification before implementation begins.

| Criterion | Verification | Status in this change |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` | Focused client contract tests against generated operations and the checked-in OpenAPI document. | Pending implementation; requires `Package.swift` and generated-source changes, which are outside this test-writing phase. |
| Per-server/profile cache and offline fallback remain intact | Existing permanent cache unit tests plus a focused `ColorCatalog` integration test that simulates a failed refresh after a cached fetch. | Pending the implementation-phase integration test. |
| Solver behavior matches server corpus, including ties | Permanent `SolverParityCorpusTests` replays every committed upstream scenario through `WeightedSquaredErrorScorer` and `CompositionSolver`. | Added in this change. |
| README describes corpus consumption and refresh | Human inspection of the README after it points to the upstream corpus and `mix parity.generate`. | Pending implementation; the repository README is intentionally outside the test/LID allowlist for this phase. |
| PR records migration notes and parity findings | PR-only human/external evidence: link the exact upstream corpus revision, test result, and any API shape differences. | Pending PR creation. |

The committed fixture is copied verbatim from `viamin/color_matching` at `priv/parity/v1/corpus.json`. The implementation-phase README must direct refreshes to that source and record its revision so changes are reviewable.
