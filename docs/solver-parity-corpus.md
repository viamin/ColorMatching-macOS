# Solver parity corpus

`ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json` is the committed
copy of the `color_matching` solver corpus from
[`viamin/color_matching` `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).

`WeightedSquaredErrorParityCorpusTests` replays every candidate score and every
one-cell solver selection. This covers exact errors, exclusion of missing
positive-weight measurements, zero-weight channels, and earliest-index tie
breaking.

To refresh the corpus, replace the fixture with the current upstream file,
review the version and scenario diff, then run `cd ColorComposerCore && swift test`.
If `algorithm_version` changes, update the test's expected version only after
confirming that the corresponding solver semantics are intentionally supported.
