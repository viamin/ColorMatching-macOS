# Issue #39 verification plan

This test-only change maps each acceptance criterion to the smallest credible
verification before the generated-client implementation begins.

| Criterion | Verification | Evidence at this PR head |
| --- | --- | --- |
| Generated client calls the published composer endpoints | Focused unit/service contract test | `PaletteAPIClientTests.testFetchColorsUsesTheProfileScopedOpenAPIPath` asserts `GET /api/v1/printer_profiles/{id}/colors`, no legacy query string, request headers, and decoded palette/profile output. It is red until the generated-client adapter is installed. |
| Disk cache is scoped by server/profile and survives offline loading | Focused unit/service tests | Existing `ProfileColorCacheTests` cover server/profile keys, disk round trips, cache misses, and usable-cache rules. The implementation run must retain them and add an app-catalog offline fallback integration test if the generated adapter changes its seam. |
| Offline-stale state and cached profile fallback remain user-visible | Human/external evidence plus focused tests | The cache unit tests establish persistence only. The implementation run must inspect the app’s `ColorCatalog` fallback path and run its focused tests; this test-only PR does not make a UI-behavior pass claim. |
| Solver choices exactly match the server, including ties, exclusions, and weight handling | Permanent unit/service test | `SolverParityCorpusTests` loads the committed upstream corpus and verifies every candidate score, selected earliest tie winner, selected hex, error, and tie indices. |
| Corpus consumption is documented | Documentation review | The implementation run must add the final README instructions. This phase cannot edit README under the test-only allowlist. |

## Corpus provenance and refresh procedure

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity-v1-corpus.json`
is copied unchanged from `viamin/color_matching` at commit
`47057afd58f7d46b4d4b740ca7d2d08947774471`, path
`priv/parity/v1/corpus.json`.

When the server bumps the corpus algorithm version, regenerate it upstream
with `mix parity.generate`, copy the resulting committed
`priv/parity/vN/corpus.json` into this fixture location, then run
`swift test --filter SolverParityCorpusTests`. Review every changed scenario:
the corpus contract includes missing-positive-channel exclusion, ignored zero
and unknown weights, exact errors, and earliest-index tie breaking.

## Current run result

The parity test is intended to pass with the current scorer. The API-path test
is intentionally red until the generated OpenAPI client replaces the legacy
`/api/v1/colors?printer_profile_id=` request. This container does not include
the `swift` executable, so neither assertion suite could be executed here.
