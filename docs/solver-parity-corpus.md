# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`
is the committed v1 golden-vector corpus consumed by
`WeightedSquaredErrorParityTests`.

The fixture is copied byte-for-byte from
[`viamin/color_matching` `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).
When the server changes its solver contract, regenerate and verify it there
with `mix parity.generate` and `mix parity.generate --check`, then copy the
new versioned corpus into this repository and update the test's expected
algorithm version. Review the resulting selection, tie, exclusion, and weight
expectations before committing the refresh.
