# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`
is the committed input for `SolverParityCorpusTests`. It asserts the palette
selection made by `WeightedSquaredErrorScorer` through `CompositionSolver`,
including weighted channels, exclusions, zero-weight channels, and ties.

The source of record is the parity corpus published by
[`viamin/color_matching#111`](https://github.com/viamin/color_matching/pull/111).
To refresh it, replace the fixture with that PR's published corpus without
changing its cases or expected selections, then run:

```bash
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

The fixture has an explicit schema version and upstream reference so a corpus
shape change is reviewed alongside the test decoder.
