# Issue #39 verification plan

| Acceptance criterion | Smallest credible verification | Status in this tests-only change |
| --- | --- | --- |
| Generated OpenAPI client replaces or wraps `PaletteAPIClient` without changing cache behavior | Focused `PaletteAPIClient` request/response tests plus the existing `ProfileColorCacheTests` cache namespace and disk-round-trip suite | Implementation follow-up |
| Per-server/profile caching, offline-stale badges, and cached profile fallback are preserved | Existing cache unit tests cover disk entries and server/profile isolation; an implementation follow-up needs an app-model integration test for offline-stale and cached-profile presentation | Cache tests already exist; UI behavior not run in this phase |
| Solver selections exactly match the server corpus, including ties | Permanent `WeightedSquaredErrorParityTests` replays every committed upstream v1 scenario through the scorer and one-cell solver | Added here |
| Corpus consumption is documented | Add the usage note to the repository README during the implementation phase; this tests-only phase is restricted from changing production documentation outside `docs/` | Deferred by phase boundary |
| PR records migration notes, API shape changes, and parity results | PR-only human review evidence | Deferred until implementation PR |

The permanent parity fixture is vendored from [`viamin/color_matching` `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json). Refresh it by replacing `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json` with the upstream file after the server runs `mix parity.generate`, then run `cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityTests`.

The corpus covers exact scores, missing-positive-channel exclusions, zero-weight channels, unknown weights, all-excluded cases, and earliest-index tie-breaking. It is deliberately a permanent unit/service test because solver parity is a recurring cross-client contract.
