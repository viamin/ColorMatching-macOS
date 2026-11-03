# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json`
is the committed v1 golden-vector corpus for the server's
`ColorMatching.WeightedSquaredError` scorer and earliest-index selection rule.
`WeightedSquaredErrorParityCorpusTests` decodes it and checks every candidate
score, exclusion, selected index, error, and tie record against the macOS
scorer and solver.

Refresh it only from the `color_matching` source of truth:

1. In `viamin/color_matching`, run `mix parity.generate` and commit the
   resulting `priv/parity/v1/corpus.json` after its own checks pass.
2. Copy that exact file here as
   `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json`.
3. Review the corpus `algorithm_version`, then run `cd ColorComposerCore && swift test`.

The corpus deliberately covers earliest-wins ties, missing-measurement
exclusions, zero-weight channels, unknown weights, and the all-excluded case.
