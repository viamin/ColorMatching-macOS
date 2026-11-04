# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`
is the committed v1 golden-vector corpus published by
[`viamin/color_matching`](https://github.com/viamin/color_matching) at
`priv/parity/v1/corpus.json`. `WeightedSquaredErrorParityTests` replays every
scenario against `WeightedSquaredErrorScorer` and checks each candidate score,
missing-measurement exclusion, selected candidate, selected error, and
earliest-index tie breaking.

When the backend changes its solver contract, regenerate its corpus with
`mix parity.generate`, review the versioned fixture, copy the new corpus into
the fixture path above, and update the test's expected algorithm version. Run
`cd ColorComposerCore && swift test` before committing the refresh.
