# Issue #39 test plan

This tests-only change maps each acceptance criterion to the smallest
credible verification before the generated-client migration is implemented.

| Criterion | Verification | Evidence at this head |
| --- | --- | --- |
| Generated OpenAPI client preserves the palette calls | Focused transport test checks `/api/v1/colors`, `printer_profile_id`, JSON accept header, bearer token, and decoded DTO envelope. | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift` (`testFetchColorsUsesVersionedEndpointAndProfileQuery`) |
| Per-server/profile disk cache remains isolated | Existing focused cache suite exercises server namespaces and same-profile IDs on distinct servers. | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift` |
| Offline-stale colors and cached-profile fallback remain intact | Human/integration verification is required: the behavior belongs to `ColorCatalog` in the macOS app and cannot be run in this Linux test environment. | Implementation PR: manually disconnect server after a successful profile/color refresh and inspect stale badge/profile fallback. |
| Solver stays in parity with `color_matching` | Permanent data-driven solver test executes every committed fixture through `CompositionSolver`, asserting the selected candidate ID exactly, including ties, exclusions, and zero-weight channels. | `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityCorpusTests.swift` and `Fixtures/weighted_squared_error_parity.json` |
| README explains corpus refresh | Documentation update is deferred to the implementation phase because this test-writing phase permits only `docs/` documentation changes. | Implementation PR README review |

## Upstream artifact status

The intended source is `viamin/color_matching#111`. The upstream GitHub API
is not authorized from this run, so the committed fixture is a temporary local
contract fixture. Before merging the implementation, replace it with the exact
committed corpus from #111 and remove this status note.
