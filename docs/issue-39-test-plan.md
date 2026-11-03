# Issue #39 verification plan

This is the tests-only phase for issue #39. The implementation run must keep
these checks green and add the generated-client implementation.

| Criterion | Smallest credible verification | Evidence at this head |
| --- | --- | --- |
| Generated OpenAPI client preserves the currently consumed API contract | Focused mocked HTTP client tests for `GET /api/v1/printer_profiles` and `GET /api/v1/colors?printer_profile_id=N`, including authorization and decoding | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift` (existing baseline); generated-client migration remains for implementation |
| Per-server/profile disk cache and offline fallback remain intact | Focused cache service tests; UI badge/fallback requires human inspection because the SwiftUI catalog is outside the package test target | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift`; human/external verification pending implementation |
| Solver matches the committed parity corpus, including ties, exclusions, and weights | Permanent corpus replay test checks every candidate score and selected solver index | `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift` and `Fixtures/weighted_squared_error_v1.json` |
| Corpus consumption is documented | README documents corpus location and refresh command | Pending implementation; this phase may only edit `docs/` |

The committed fixture is copied byte-for-byte from
`viamin/color_matching` commit `47057afd58f7d46b4d4b740ca7d2d08947774471`,
at `priv/parity/v1/corpus.json`. Refresh it after a server corpus release,
review the algorithm version and fixture diff, then run `swift test` from
`ColorComposerCore`.
