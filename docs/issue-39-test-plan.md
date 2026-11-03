# Issue #39 acceptance-criterion test plan

This red-phase change records the smallest verification for each issue
criterion before production code is changed.

| Criterion | Verification | Current evidence |
| --- | --- | --- |
| Generated OpenAPI client replaces the hand-written transport | Focused package-contract test | `GeneratedOpenAPIClientAdoptionTests.testCorePackageDeclaresOpenAPIRuntimeAndGenerator` is red until the runtime and generator are declared in `ColorComposerCore/Package.swift`. Endpoint behavior remains covered by `PaletteAPIClientTests`. |
| Per-server/profile cache and offline fallback remain unchanged | Focused unit/service tests | Existing `ProfileColorCacheTests` exercise server/profile isolation. The app-shell fallback paths require a macOS/Xcode integration run in the implementation PR. |
| Solver selections match the parity corpus, including ties | Focused unit/service test | `SolverParityTests` loads the committed JSON fixture and checks selected ID, excluded-candidate count, and exact score/unmatched outcome for each case. |
| README records corpus location and refresh procedure | Human/document review | Blocked in this test-only phase because `README.md` is outside the permitted documentation allowlist. Add it in the implementation phase after importing the authoritative viamin/color_matching#111 fixture. |
| PR description records generated-client migration and parity findings | Human/external evidence | To be supplied by the implementation PR author after the authoritative upstream corpus and OpenAPI document are accessible. |

## Corpus provenance

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`
defines the local executable corpus interface and currently covers the required
selection, tie, exclusion, and zero-weight behaviors. The private upstream
artifact from `viamin/color_matching#111` was not accessible from this run, so
the implementation phase must replace or verify this fixture against the
authoritative committed corpus before claiming full upstream parity.
