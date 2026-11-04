# Issue #39 verification plan

| Criterion | Verification | Evidence location |
| --- | --- | --- |
| Generated OpenAPI client preserves the palette API contract | Focused `PaletteAPIClient` request/response test; the implementation run must replace the handwritten transport while keeping this public behavior. | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift` |
| Per-server/profile disk cache remains isolated | Permanent cache unit tests cover separate server namespaces and the same profile ID on more than one server. | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift` |
| Offline-stale and cached-profile fallback remain unchanged | Human inspection is required because the SwiftUI catalog state owns the badge and fallback presentation; the implementation PR must record the manual result. | `ColorMatching/Networking/ColorCatalog.swift` |
| Solver matches the server corpus | Permanent corpus replay test checks every candidate score, exclusion, selected color, selected index, tie set, and solver result where a complete target can be represented as source grids. | `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityTests.swift` |
| Corpus consumption is documented | The implementation run must add the user-facing README refresh instructions. The corpus is vendored at `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json`. | README change pending implementation phase |

The fixture is copied byte-for-byte from `viamin/color_matching` at
`priv/parity/v1/corpus.json` (algorithm version 1). Refresh it by obtaining the
upstream fixture, replacing the vendored file, and running `swift test` from
`ColorComposerCore`. Any corpus algorithm-version increase requires a matching
test/fixture update and explicit migration review.
