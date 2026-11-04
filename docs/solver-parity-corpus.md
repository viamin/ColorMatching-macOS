# Solver parity corpus

`ColorComposerCoreTests/SolverParityCorpusTests.swift` replays the committed
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`
fixture through `WeightedSquaredErrorScorer`. It checks each candidate score,
missing-measurement exclusion, selected palette index, selected hex color, and
earliest-index tie behavior.

The fixture is copied from the `color_matching` server repository at
`priv/parity/v1/corpus.json`, introduced by
[`a82aec5` (color_matching#111)](https://github.com/viamin/color_matching/commit/a82aec5441d2a7b0100e8c8ab81d573e11ace9b0).
It is generated and verified there with:

```bash
mix parity.generate
mix parity.generate --check
```

When the server's `algorithm_version` changes, run the server generation,
replace the committed fixture with that generated file, and update the Swift
corpus test only as needed to decode the new contract. Review all expected
score, exclusion, weight, and tie changes before committing the refresh.
