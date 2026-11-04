# Issue #39 verification plan

This test-writing PR maps each acceptance criterion to the smallest credible verification before the generated-client implementation begins.

| Criterion | Verification | Evidence at implementation PR head |
| --- | --- | --- |
| Typed client generated from the `color_matching` OpenAPI document and used by `PaletteAPIClient` | Human/code inspection plus focused request tests against a `URLProtocol` transport | Generated source, package dependency declarations, and `PaletteAPIClientTests` covering the two consumed `/api/v1` operations, query encoding, bearer authorization, and generated response mapping |
| Per-server/profile disk cache, offline-stale badge, and cached-profile fallback remain intact | Permanent system test | App-model/system test that simulates a failed refresh after a cached profile fetch and verifies the cached colors, stale state, and profile picker fallback; retain the existing `ProfileColorCacheTests` for server/profile isolation |
| `WeightedSquaredErrorScorer` remains in solver parity | Focused permanent unit/service test | `SolverParityCorpusTests.swift` replays every committed vector in `Fixtures/solver-parity-v1.json`, asserting scores, exclusions, selection, selection error, and earliest-index tie results |
| README explains parity corpus refresh | Human/code inspection | README links the upstream `priv/parity/v1/corpus.json`, names its source revision/version, and gives the copy/refresh command plus the Swift test command |
| PR notes API shape differences and parity results | Human/external evidence | PR description records inspection of `/api/v1/openapi.json`, generated-client adaptation notes, and the passing parity scenario count including ties, exclusions, and zero/unknown weights |

## Corpus provenance

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json` is the deterministic corpus from [`viamin/color_matching`](https://github.com/viamin/color_matching), `priv/parity/v1/corpus.json`, algorithm version 1. It was copied from backend commit `47057afd58f7d46b4d4b740ca7d2d08947774471` during this test-writing run. The upstream generator is `mix parity.generate`; upstream CI checks it with `mix parity.generate --check`.

The implementation PR must document the normal refresh workflow in the repository README and retain this exact replay test as the guard against solver drift.
