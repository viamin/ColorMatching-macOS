# Issue #39 verification plan

This tests-only change establishes the recurring solver contract before the generated-client migration is implemented.

| Criterion | Smallest credible verification | Evidence at this revision |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` | Inspect generated sources, package dependencies, and wrapper integration after the implementation change. | Not runnable in this tests-only revision. |
| Per-server/profile caching, offline-stale badges, and cached-profile fallback are preserved | Existing focused cache tests plus an integration test of `ColorCatalog` in the implementation revision. | Existing `ProfileColorCacheTests`; no new implementation is permitted in this revision. |
| Solver selections match the committed parity corpus, including ties | Permanent corpus-driven Core test: every recorded score, selection, error, exclusion, and tied index is asserted. | `WeightedSquaredErrorParityTests.swift` and `Resources/weighted-squared-error-v1.json`. |
| README documents corpus consumption and refresh | Review the README edit in the implementation revision against the upstream refresh command. | Not runnable in this tests-only revision. |
| PR records migration and parity findings | Human review of the eventual PR description. | Not runnable in this tests-only revision. |

## Corpus provenance and refresh

The committed fixture is copied byte-for-byte from `viamin/color_matching` at
`priv/parity/v1/corpus.json` (algorithm version 1). Refresh it only after the
backend changes the corpus: run `mix parity.generate` in that repository,
review the resulting corpus, replace
`ColorComposerCore/Tests/ColorComposerCoreTests/Resources/weighted-squared-error-v1.json`,
and run the parity test. The implementation revision must mirror this guidance
in the public README.
