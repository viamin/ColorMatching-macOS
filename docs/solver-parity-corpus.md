# Solver parity corpus

`ColorComposerCoreTests` loads the committed v1 corpus at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`.
It is a checked-in copy of
[`viamin/color_matching`'s `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json),
published by [color_matching#111](https://github.com/viamin/color_matching/issues/111).

The corpus is the cross-language contract for `WeightedSquaredErrorScorer` and
`CompositionSolver`: it asserts every candidate score and final selection,
including earliest-index ties, missing positive-weight measurements, and
zero-weight channels.

To refresh it, run the server's `mix parity.generate`, review the server-side
fixture diff, then replace the local fixture with the resulting
`priv/parity/v1/corpus.json`. Run `cd ColorComposerCore && swift test` before
committing. Do not edit expected selections or errors locally: solver behavior
changes must first be versioned by the server corpus.
