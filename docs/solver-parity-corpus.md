# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`
is the committed v1 corpus published by `viamin/color_matching` at
`priv/parity/v1/corpus.json`. `WeightedSquaredErrorParityTests` replays every
scenario against `WeightedSquaredErrorScorer`, including exclusions, channel
weights, and earliest-index tie-breaking.

Refresh the fixture only after the upstream corpus changes:

1. Run `mix parity.generate --check` in `viamin/color_matching` to verify the
   upstream fixture is current.
2. Copy `priv/parity/v1/corpus.json` over the macOS fixture without modifying
   its contents.
3. Run `cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityTests`.

An `algorithm_version` increase means the solver contract changed and requires
review before updating the fixture.
