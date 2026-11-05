# Issue #39 verification plan

This test-writing change establishes the verification contract before the
generated-client migration is implemented.

| Criterion | Smallest credible verification | Current evidence |
| --- | --- | --- |
| Generated OpenAPI client replaces/wraps `PaletteAPIClient` | Focused client contract tests using the generated operations, including `/api/v1/printer_profiles` and `/api/v1/colors?printer_profile_id=N` | Planned for implementation phase; no generated client exists in this test-only commit. |
| Per-server/profile cache, offline-stale badge, cached-profile fallback remain intact | Existing cache unit tests plus a focused `ColorCatalog` integration test through a failed transport | Existing `ProfileColorCacheTests`; `ColorCatalog` test must be added in the implementation phase because it is outside the Swift package test target. |
| Solver selections match the server corpus, including ties | Permanent unit test replaying the committed v1 corpus exactly | `WeightedSquaredErrorParityTests.testReplaysCommittedV1ParityCorpusExactly`. |
| Corpus consumption documented | README describes the committed fixture path and repeatable upstream refresh command | Deferred: the test-writing phase only permits test paths and LID documentation. |

The committed fixture is copied byte-for-byte from
`viamin/color_matching` `priv/parity/v1/corpus.json` (algorithm version 1).
During the implementation phase, refresh it from that path after the backend
has regenerated it with `mix parity.generate`, then run
`cd ColorComposerCore && swift test`.
