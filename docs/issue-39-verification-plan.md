# Issue #39 verification plan

This test-writing change establishes the checks that the implementation run
must satisfy.

| Criterion | Smallest credible verification | Evidence at implementation completion |
| --- | --- | --- |
| Generated OpenAPI client is used for the two palette endpoints | Focused URL-protocol integration tests for profile and color operations, including `/api/v1`, auth, query encoding, and decode behavior | `PaletteAPIClientTests` result and generated source/spec review |
| Per-server/profile cache and offline fallback remain intact | Existing permanent `ProfileColorCacheTests` exercise disk round trips and server/profile isolation; application-level cache fallback requires a macOS app test or manual inspection | Test result plus inspection of `ColorCatalog` offline-stale state |
| Solver matches the server | Permanent `SolverParityCorpusTests` replays the committed versioned upstream corpus through both the scorer and production solver | Exact score, exclusion, selection, error, and tie assertions |
| Corpus consumption is documented | README records this repository fixture and its upstream source, including refresh instructions | README review |

## Corpus source and refresh

The canonical corpus is generated and committed by
[`viamin/color_matching`](https://github.com/viamin/color_matching) at
`priv/parity/v1/corpus.json`. This repository pins the copied fixture at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`.

To refresh it after the server intentionally bumps its algorithm version:

1. Run `mix parity.generate` in `viamin/color_matching` and commit its output
   there.
2. Copy the resulting `priv/parity/vN/corpus.json` into the core test fixtures,
   retaining the version in the filename.
3. Update `SolverParityCorpusTests` only for intentional schema/version changes,
   then run `cd ColorComposerCore && swift test`.

The fixture tests earliest-index tie selection, required-channel exclusions,
zero-weight behavior, exact errors, and unknown upstream weight keys.
