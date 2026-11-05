# Solver parity corpus

`ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json` is a committed
copy of the v1 corpus produced by
[`viamin/color_matching#111`](https://github.com/viamin/color_matching/issues/111).
`WeightedSquaredErrorParityTests` decodes it and checks each candidate score,
exclusion, winning palette index, and expected winner hex value. The test also
exercises `CompositionSolver` for every scenario whose target has every active
channel, covering its earliest-wins behavior.

To refresh the fixture, retrieve
`priv/parity/v1/corpus.json` from the `color_matching` repository, replace the
fixture byte-for-byte, then run `swift test` from `ColorComposerCore`. Review
the upstream `algorithm_version`, scenario count, and any resulting selection
or score changes before committing the refresh.

The implementation phase must add this consumption note to the repository
README as required by issue #39; the test-writing phase only permits docs and
test-path changes.
