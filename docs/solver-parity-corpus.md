# Solver parity corpus

`ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json` is the committed v1 golden-vector corpus shared with [`viamin/color_matching`](https://github.com/viamin/color_matching). `WeightedSquaredErrorParityTests` loads the fixture and checks each recorded per-candidate score, exclusion, selected palette index, error, and tie set through `WeightedSquaredErrorScorer` and the default `CompositionSolver` path.

Refresh it only after the backend changes the scorer contract:

1. In `viamin/color_matching`, run `mix parity.generate` and review the resulting `priv/parity/v1/corpus.json`.
2. Copy that exact version into `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`.
3. Update the test's asserted algorithm version if the backend increments it, then run `cd ColorComposerCore && swift test`.

The fixture deliberately covers earliest-index tie breaking, exclusions for missing positively weighted channels, zero-weight ignored channels, and channel-weighted scoring. It is a test-only contract artifact; production behavior must not synthesize or modify it.
