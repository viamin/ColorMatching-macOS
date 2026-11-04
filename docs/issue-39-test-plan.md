# Issue 39 verification plan

| Criterion | Smallest credible verification | Status in tests-only phase |
| --- | --- | --- |
| Generated OpenAPI client replaces hand-written transport | `GeneratedOpenAPIClientContractTests` asserts the package declares the runtime, generator, and generator plugin; implementation review verifies `PaletteAPIClient` delegates to generated operations. | Red: dependencies/plugin absent. |
| Per-server/profile cache and offline fallback remain intact | Existing `ProfileColorCacheTests` cover server/profile isolation and cache storage. A subsequent implementation run must add a `ColorCatalog` integration test for transport failure serving an offline-stale cache and cached-profile fallback. | Not added here: app target is outside the SwiftPM test package. |
| Solver selections match the committed backend corpus | `WeightedSquaredErrorParityCorpusTests` loads the committed JSON fixture and executes the production solver. Fixture cases cover selection, earliest-wins ties, missing-measurement exclusions, zero-weight channels, and nonuniform weights. | Green once the fixture is replaced/confirmed against `viamin/color_matching#111`. |
| README documents corpus refresh | Human inspection of README. | Deferred: this tests-only run may modify only test paths and `docs/`. |
| PR notes migration, API shape, parity results | PR description inspection. | External/human evidence required. |

## External dependency note

The exact published corpus from `viamin/color_matching#111` was unavailable to this isolated run (the repository API returned 404). Before implementation approval, replace `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json` with the upstream artifact byte-for-byte or record its immutable source revision and any intentional adapter. Do not treat the locally seeded cases as proof of upstream parity.
