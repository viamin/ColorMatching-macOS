# Solver parity corpus

`ColorComposerCoreTests` replays the committed fixture at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`
against `WeightedSquaredErrorScorer` and `CompositionSolver`.

The fixture is copied verbatim from
[`viamin/color_matching` `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).
It currently matches upstream commit `7d07b92` (SHA-256
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`).

To refresh it after the server changes scoring semantics:

1. Run `mix parity.generate` in `color_matching` and confirm
   `mix parity.generate --check` passes there.
2. Copy the generated `priv/parity/v1/corpus.json` here unchanged.
3. Update the upstream commit and SHA-256 above, then run
   `cd ColorComposerCore && swift test`.

The corpus explicitly covers the earliest-index tie policy, exclusions for
missing positive-weight channels, and zero/positive channel weights. A new
`algorithm_version` requires reviewing and accepting the entire fixture change.
