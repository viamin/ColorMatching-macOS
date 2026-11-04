# Issue #39 criterion verification plan

This is the tests-only phase. The generated-client implementation and its
README update are intentionally deferred until the implementation phase.

| Criterion | Smallest credible verification | Evidence in this phase |
| --- | --- | --- |
| Typed OpenAPI client migration | Focused `PaletteAPIClient` request/response contract tests, then human review of generated source and `/api/v1` shape changes | Planned for implementation phase |
| Per-server/profile cache and offline fallback | Focused `ProfileColorCacheTests` plus an API-client/cache integration test for stale colors and cached profiles | Existing coverage; rerun after migration |
| Solver parity corpus | Permanent `WeightedSquaredErrorParityTests` replays every v1 corpus scenario against the scorer and default solver | Added in this commit |
| Corpus consumption documentation | README states corpus location and the backend `mix parity.generate` refresh flow | Planned for implementation phase because this test-writing phase may only commit test/LID paths |
| PR migration notes and parity results | Inspectable PR body after implementation tests run | Not applicable before a PR exists |

The vendored corpus is copied byte-for-byte from
`color_matching` `priv/parity/v1/corpus.json` (algorithm v1). To refresh it,
run `mix parity.generate` in that repository, review the generated corpus and
its algorithm version, copy it to
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`,
and run `cd ColorComposerCore && swift test`.
