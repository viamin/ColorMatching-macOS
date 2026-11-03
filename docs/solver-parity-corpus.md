# Solver parity corpus

`ColorComposerCoreTests/SolverParityCorpusTests.swift` replays the committed
version 1 corpus in `ColorComposerCore/Tests/ColorComposerCoreTests/Resources/ParityCorpus/v1/corpus.json`
against `CompositionSolver` and its default `WeightedSquaredErrorScorer`.

The source of truth is
[`viamin/color_matching`'s `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json),
published by [color_matching#111](https://github.com/viamin/color_matching/issues/111).
To refresh it, download that file without reformatting, replace the committed
fixture, and run `cd ColorComposerCore && swift test --filter SolverParityCorpusTests`.
Review its `algorithm_version`, fixture diff, and test result before committing;
a new algorithm version requires corresponding client review.
