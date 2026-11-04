# Issue #39 verification plan

This tests-only change maps the issue acceptance criteria to durable evidence before
the generated-client migration is implemented.

| Criterion | Verification | Expected initial result |
| --- | --- | --- |
| Generated OpenAPI client is adopted by `ColorComposerCore` | `GeneratedOpenAPIClientContractTests.testPackageDeclaresOpenAPIGeneratorRuntimeAndBuildPlugin` checks the package manifest for the generator, runtime, and build plugin. | Fails until the migration adds the dependencies and plugin. |
| `/api/v1` palette/profile behavior keeps its cache and offline fallback contract | Existing `PaletteAPIClientTests` validates request authentication and API failures; `ProfileColorCacheTests` covers server/profile cache isolation and fallback-ready entries. Implementation must retain these tests green. | Passing before and after migration. |
| Weighted-squared-error selections remain server-parity compatible | `SolverParityCorpusTests.testWeightedSquaredErrorMatchesCommittedParityCorpus` replays every committed v1 corpus scenario, including ties, exclusions, zero-weight channels, and per-candidate scores. | Passing. |
| Corpus provenance and refresh process are documented | README update is deliberately deferred to the implementation phase because this tests-only run may edit only tests and LID documentation. It must identify upstream `viamin/color_matching` `priv/parity/v1/corpus.json`, copy it unchanged to this fixture path, and describe regenerating upstream with `mix parity.generate` followed by reviewing and committing the fixture update. | Not run in this phase. |

The committed fixture in `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/Parity/v1/corpus.json` is copied unchanged from `viamin/color_matching` `priv/parity/v1/corpus.json` (algorithm version 1). Upstream produces it deterministically with `mix parity.generate`; use `mix parity.generate --check` in that repository before copying a refresh.
