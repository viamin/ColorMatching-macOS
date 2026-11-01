# Issue 39 verification plan

| Criterion | Smallest credible verification | Status in test-writing phase |
| --- | --- | --- |
| Generated OpenAPI client handles the endpoints used by `PaletteAPIClient` | Focused client contract tests using mocked generated-client transport, including authorization and the profile/colors response shapes | Deferred to implementation: the generated target does not exist yet. |
| Per-server/profile cache, offline-stale badge, and cached-profile fallback are preserved | Existing cache unit tests cover server/profile isolation and servable stale entries. A future app-level integration test must verify the UI badge and profile-picker fallback. | Existing core coverage; app-level evidence not yet available. |
| Weighted squared-error parity | `WeightedSquaredErrorParityTests` loads the committed v1 corpus and verifies every candidate score, exclusion, selected index/hex/error, and the solver fast path where a complete target can be represented. | Added in this change. |
| Corpus consumption is documented | README documentation naming the upstream corpus and a refresh procedure. | Deferred to implementation because this test-writing run may only commit files under `docs/` and test paths. |

## Corpus source and refresh procedure

The vendored fixture is `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`. It is sourced from [`viamin/color_matching` `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json), introduced by the solver-parity corpus work tracked in `viamin/color_matching#111`.

When upstream deliberately changes the contract, replace the fixture with that file, retain all scenarios, and run:

```bash
cd ColorComposerCore
swift test --filter WeightedSquaredErrorParityTests
```

Review any changed expected selections carefully: ties must keep the earliest palette index, channels missing at a positive weight must exclude a candidate, and channels at zero weight must not contribute or exclude.
