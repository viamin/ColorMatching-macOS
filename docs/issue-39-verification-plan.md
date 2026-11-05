# Issue #39 verification plan

This tests-only change establishes the smallest credible verification for each
acceptance criterion before implementation begins.

| Criterion | Verification | Status in this phase |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` | Focused API-client contract tests for printer profiles, colors query parameters, response decoding, authentication, and non-2xx mapping. | Existing tests cover the legacy client; generated-client coverage is implementation work. |
| Per-server/profile cache and offline fallback remain intact | Permanent unit/service tests in `ProfileColorCacheTests` and `ColorCatalog` behavior tests, covering server isolation, cached profile fallback, and offline-stale state. | Existing tests are retained; execution requires Swift tooling. |
| Weighted solver remains in parity with the server | Permanent `WeightedSquaredErrorParityCorpusTests` replaying every v1 corpus candidate score and selection, including exclusion, zero-weight, unknown-weight, and earliest-wins tie cases. | Red: it requires the committed upstream fixture at `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`. |
| Corpus consumption is documented | Human review of the README: it must name upstream `viamin/color_matching/priv/parity/v1/corpus.json`, the local copied-fixture path, upstream regeneration command, and the copy/verification refresh procedure. | Deferred to implementation because this test-writing phase may not modify `README.md`. |
| PR notes record migration and parity findings | Inspect the PR description for generated-client notes, observed `/api/v1` shape changes, and test findings on ties, exclusions, and weights. | Requires PR creation/update outside this tests-only commit. |

The parity test deliberately decodes the upstream JSON schema directly. Its
metadata assertions pin algorithm version 1, the missing-measurement policy,
earliest-index selection, and all 12 currently published scenarios so a fixture
refresh is an explicit review event.
