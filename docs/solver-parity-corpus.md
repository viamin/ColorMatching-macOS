# Solver parity corpus

`ColorComposerCoreTests/Fixtures/WeightedSquaredError/v1/corpus.json` is the
committed v1 golden-vector corpus from
[`viamin/color_matching` issue #111](https://github.com/viamin/color_matching/issues/111).
`WeightedSquaredErrorParityCorpusTests` decodes and replays every scenario
against `WeightedSquaredErrorScorer`, including exact scores, missing-response
exclusions, channel weights, and earliest-index tie selection.

Refresh the fixture only after the upstream corpus changes:

1. Run `mix parity.generate` in `viamin/color_matching` and commit its
   byte-identical `priv/parity/v1/corpus.json` there.
2. Copy that committed file into
   `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/WeightedSquaredError/v1/corpus.json`.
3. Run `swift test` from `ColorComposerCore`; the parity test must pass before
   updating the app's expected algorithm-version assertion.

The current consumer accepts only `algorithm_version: 1`. A server-side
algorithm-version increase requires an explicit macOS review, fixture update,
and parity-test update; it must not be silently accepted.
