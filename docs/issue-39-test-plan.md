# Issue #39 verification plan

This tests-only change maps each acceptance criterion to the smallest credible verification before the generated-client implementation begins.

| Criterion | Verification | Evidence status |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` | Focused `PaletteAPIClient` transport/decoding tests against generated operations, added during implementation | Not run: generated client is outside the tests-only phase. |
| Per-server/profile cache and offline-stale fallback are unchanged | Permanent focused cache/client tests for server namespace, cached profile fallback, and stale colors | Existing coverage to be reviewed and extended during implementation. |
| Solver selections exactly match the backend corpus, including ties | Permanent unit test: `SolverParityCorpusTests.testWeightedSquaredErrorMatchesCommittedParityCorpus` | Added in this change. It replays the committed upstream v1 corpus's scores, exclusions, selections, and earliest-wins ties. |
| Corpus consumption is documented | README inspection | Added in this change. |
| PR records client migration, API-shape findings, and parity results | Human/external PR review evidence | Not run: implementation PR description has not been created. |

## Corpus consumption and refresh

`ColorComposerCoreTests` replays the committed fixture at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`.
Its source of truth is `viamin/color_matching` issue #111's
[`priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json), generated there with `mix parity.generate`.

When the backend publishes a new corpus version, copy the generated JSON into
the matching test fixture, update the replay test only for an intentional schema
change, then run `cd ColorComposerCore && swift test`. The fixture is committed
deliberately: parity tests must run offline and pin the exact server behavior
they verify. The implementation-phase PR must add this same note to the README.
