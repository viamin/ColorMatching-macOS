# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`
is the committed v1 golden-vector corpus for
`WeightedSquaredErrorScorer` and `CompositionSolver`. Its upstream source of
truth is
[`viamin/color_matching` `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).

The permanent `WeightedSquaredErrorParityCorpusTests` replays every scenario:
individual scores, excluded candidates, chosen color/error, and exact
earliest-index tie-breaking. The fixture intentionally includes zero-weight
channels and missing measurements.

## Refreshing the fixture

1. Update the server corpus with `mix parity.generate` in
   `viamin/color_matching` and commit the resulting versioned fixture there.
2. Copy that exact JSON file into this repository at
   `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_vN.json`.
3. Update the test fixture path and expected `algorithm_version`, then run
   `cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityCorpusTests`.

Do not hand-edit expected scores. A server-side semantic change must increment
the corpus algorithm version before this client adopts it.
