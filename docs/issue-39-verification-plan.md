# Issue #39 verification plan

This test-writing change defines the smallest credible evidence for each
acceptance criterion before implementation begins.

| Criterion | Verification | Evidence at PR head |
| --- | --- | --- |
| Generated OpenAPI client migrates PaletteAPIClient | A permanent package-contract test requires the generator plugin and runtime; focused API-client tests must then exercise generated operations for profiles, colors, authorization, status mapping, and snake-case response decoding. | ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIClientPackageTests.swift is intentionally red until implementation adds the package dependencies. |
| Per-server/profile disk cache and offline-stale behavior remain intact | Existing focused cache tests cover per-server keys, cached profiles, and stale-entry handling. The implementation run must run these unchanged and add an app-level integration test only if the migration changes the cache boundary. | ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift |
| Solver matches the committed parity corpus, including ties | Permanent unit/service test replays every committed corpus scenario through WeightedSquaredErrorScorer and CompositionSolver, asserting score table, selection, error, and tied indices exactly. | ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityCorpusTests.swift and Fixtures/weighted_squared_error_v1.json |
| README explains corpus consumption and refresh | Inspectable documentation review against the upstream corpus location and refresh command. | Deferred: this red-phase run may only modify docs; implementation run must update README.md. |
| PR describes generated-client migration, API shape changes, and parity results | Inspectable PR body with links to the generated OpenAPI source, corpus test result, and any observed wire-shape differences. | Deferred until an implementation PR exists. |

## Corpus provenance and refresh

The fixture is copied verbatim from viamin/color_matching at
priv/parity/v1/corpus.json. The backend owns the format and regenerates it with:

    mix parity.generate

When the backend changes the corpus or its algorithm_version, copy the new
committed JSON into
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json,
run the parity test, and update the README consumption note in the
implementation run. Do not edit expected scores manually.
