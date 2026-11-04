# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json`
is the committed v1 fixture from the `color_matching` repository's
`priv/parity/v1/corpus.json`. `WeightedSquaredErrorParityTests` replays every
scenario against `WeightedSquaredErrorScorer` and `CompositionSolver`.

The corpus captures the coupled scorer and selection contracts: weighted
squared errors, missing-value exclusion, ignored zero-weight channels, and
earliest-index tie-breaking. It is intentionally a test fixture, not runtime
application data.

## Refreshing the fixture

1. In the `color_matching` checkout, regenerate and validate the source:
   `mix parity.generate --check`.
2. Copy `priv/parity/v1/corpus.json` over this repository's
   `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json`.
3. Review the corpus `algorithm_version` and scenario changes, then run
   `cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityTests`.

When upstream changes solver semantics, update the fixture and this test in the
same change; do not adjust expected selections independently.
