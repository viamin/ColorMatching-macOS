# Weighted-squared-error parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`
is the solver contract fixture for `WeightedSquaredErrorScorer`. Its cases are
run by `SolverParityCorpusTests` with the production `CompositionSolver`.

The canonical corpus is published by
[`viamin/color_matching` pull request #111](https://github.com/viamin/color_matching/pull/111).
When that corpus changes, copy its cases into the committed fixture without
changing their order, then run:

```bash
cd ColorComposerCore
swift test --filter SolverParityCorpusTests
```

The fixture must preserve exact expected selections, including equal-score
ties. It also records active-channel exclusions and weighted/zero-weight
handling, so a solver change cannot silently drift from the backend contract.
