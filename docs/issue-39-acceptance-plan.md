# Issue 39 acceptance plan

This red-phase change adds the recurring solver-parity regression test. The
fixture is an unchanged copy of the backend corpus at
`viamin/color_matching/priv/parity/v1/corpus.json`.

| Criterion | Verification | Current phase |
| --- | --- | --- |
| Generated OpenAPI client replaces or wraps `PaletteAPIClient` | Focused API-client tests that exercise typed profile/color decoding plus existing cache/offline fallback tests | Deferred to implementation phase; no generated client exists yet. |
| Per-server/profile disk cache, offline-stale badge, and cached-profile fallback stay unchanged | Existing app-model/cache tests plus an implementation-phase integration test using a failing transport after a successful cached fetch | Deferred to implementation phase. |
| `WeightedSquaredErrorScorer` agrees with the backend corpus, including exclusions, weights, and ties | `WeightedSquaredErrorParityTests.testMatchesCommittedColorMatchingParityCorpus` decodes every scenario and checks each candidate score, selected index/hex/error, and exact tied indices | Added in this change. |
| README explains corpus refresh | Human review of README text identifying the backend corpus path and `mix parity.generate` refresh command | Deferred: this tests-only phase may not modify `README.md`. |
| PR description records generated-client notes, API-shape differences, and parity results | Human/external evidence against the implementation PR description | Deferred to implementation/PR creation. |

Refresh the committed fixture only after changing the backend solver corpus:

1. Generate and verify it in `viamin/color_matching` with `mix parity.generate --check`.
2. Copy `priv/parity/v1/corpus.json` to
   `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`.
3. Run the parity test before committing.

The corpus contains a scenario with an unknown `ultraviolet` weight. The test
only maps the app's five supported `LightingCondition` values, so that scenario
also guards the server contract that unknown channels do not alter selection.
