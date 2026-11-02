# Issue #39 verification plan

This test-writing change maps each acceptance criterion to inspectable evidence
for the implementation PR.

| Criterion | Smallest credible verification | Expected evidence |
| --- | --- | --- |
| Generated OpenAPI client replaces the hand-written transport | Focused `PaletteAPIClient` service tests inject a URL protocol and assert the generated-client adapter sends the contract paths, query parameter, bearer token, and decodes the published response envelopes. | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift` |
| Per-server/profile disk cache, offline-stale state, and cached-profile fallback remain intact | Existing focused cache unit tests cover server namespaces and disk round-trips. The app-level fallback remains an external/UI behavior and must be inspected in the implementation PR. | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift`; implementation PR manual evidence |
| Solver stays in parity with `color_matching` | Permanent corpus test replays every committed v1 vector through the public scorer and one-cell solver, checking individual scores, exclusions, selected index/hex/error, and earliest-wins ties. | `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityTests.swift`; `Fixtures/weighted_squared_error_v1.json` |
| README documents corpus location and refresh process | Documentation review against the committed upstream source and refresh command. | README diff in implementation PR (human/inspectable evidence) |
| PR description records migration, shape changes, and parity findings | Human review of the implementation PR body. | Pull request description (human/external evidence) |

The corpus fixture is vendored verbatim from
`https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json`
(SHA-256 `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`).
Refresh it only from that versioned upstream path, then run `swift test` in
`ColorComposerCore`.
