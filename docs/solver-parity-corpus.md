# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`
is the committed v1 parity fixture consumed by `WeightedSquaredErrorParityTests`.
It is sourced from `viamin/color_matching` at
`priv/parity/v1/corpus.json` (introduced for backend issue #111).

To refresh the fixture after the backend changes it, run
`mix parity.generate` in the backend repository, copy its committed
`priv/parity/vN/corpus.json` into the corresponding core-test fixture path,
and update the parity test's accepted algorithm version. The test must retain
the corpus assertions for scores, exclusions, selected color/index, error, and
earliest-index tie handling.
