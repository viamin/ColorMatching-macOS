# Issue #39 verification plan

| Acceptance criterion | Smallest credible verification | Status in test-writing run |
| --- | --- | --- |
| Generated OpenAPI client preserves the palette/profile contract | `PaletteAPIClientTests` request/response contract tests; implementation run adds generated-client dependency and generation check | Planned |
| Per-server/profile cache, offline stale badge, cached-profile fallback remain unchanged | Existing `ProfileColorCacheTests` plus app-level catalog tests in the implementation run | Planned |
| Solver selections remain identical to `color_matching` | Permanent `SolverParityCorpusTests`, replaying `color_matching/priv/parity/v1/corpus.json` | Added |
| Corpus consumption is documented | README update in implementation run: identify the committed fixture and upstream refresh command | Planned |
| PR records migration notes and parity findings | PR description, requiring human/external inspection | Pending |

The fixture is copied from `viamin/color_matching`'s `priv/parity/v1/corpus.json` (algorithm version 1). Refresh it by checking out the upstream repository, running `mix parity.generate`, and replacing `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json` with the generated corpus before running `swift test`.
