# Issue #39 verification plan

| Acceptance criterion | Verification | Status in this tests-only change |
| --- | --- | --- |
| Generated OpenAPI client replaces the hand-written endpoint decoding without changing the consumer contract | Focused `PaletteAPIClient` request/response tests; inspect generated source and dependency declarations in the implementation PR | Not yet run: implementation is intentionally out of scope for this red-phase PR. |
| Per-server/profile cache, offline-stale badges, and cached-profile fallback remain unchanged | Existing focused cache and catalog tests, plus a manual offline UI check in the implementation PR | Not yet run: requires the implementation change and macOS UI evidence. |
| Solver selection matches the committed backend corpus exactly | Permanent unit test: `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityTests.swift` loads the vendored upstream v1 corpus and compares every score, selection, error, tie, and exclusion | Added. |
| Corpus consumption is documented | README section identifying `viamin/color_matching/priv/parity/v1/corpus.json` and its refresh command | Deferred to implementation PR because this tests-only phase cannot modify root `README.md`. |
| PR description records generated-client migration, API-shape changes, and parity results | Inspect PR body against the implementation and test output | Not yet run: needs the implementation PR. |

The vendored fixture is an unmodified copy of `viamin/color_matching` issue #111's
`priv/parity/v1/corpus.json` (SHA-256
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`).
The implementation PR should refresh it from that path, review the diff, and run
`cd ColorComposerCore && swift test`.
