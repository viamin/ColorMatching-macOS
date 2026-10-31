# Issue 39 verification plan

This test-writing change establishes the regression contract before the generated-client migration is implemented.

| Acceptance criterion | Credible verification | Status in this change |
| --- | --- | --- |
| Generated OpenAPI client replaces the handwritten `/api/v1` client | Focused `PaletteAPIClient` contract tests using generated operation types and mock transport | Planned for implementation phase; existing tests keep bearer-token and response-decoding coverage. |
| Server/profile disk cache and offline-stale fallback remain intact | Focused `ProfileColorCacheTests` plus an integration-level `ColorCatalog` offline fallback test | Planned for implementation phase; existing cache tests cover server/profile isolation and persisted entries. |
| Solver remains in parity with `color_matching` | Permanent unit test replaying the committed corpus | Added: `WeightedSquaredErrorParityTests.testCommittedParityCorpusMatchesScoresSelectionsAndTieEvidence`. |
| README documents corpus location and refresh | Inspectable README update referring to `priv/parity/v1/corpus.json` in `viamin/color_matching` and `mix parity.generate` | Planned for implementation phase because this phase permits LID documents, not root README changes. |
| PR records migration notes, API shape findings, and parity results | PR description reviewed against implementation diff and test output | Human/external evidence required when the PR is opened. |

The committed fixture is copied verbatim from `viamin/color_matching` pull request #111 (`priv/parity/v1/corpus.json`). The permanent replay test asserts every candidate score, exclusion, selected index and hex color, error, and tie set; it therefore covers tie-breaking, missing-measurement exclusion, and channel weighting without changing solver semantics.

When the upstream algorithm version changes, refresh the fixture from its committed upstream path, update the expected algorithm version, and run `cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityTests` before the full suite.
