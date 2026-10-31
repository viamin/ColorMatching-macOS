# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Resources/SolverParity/v1/corpus.json`
is the committed golden-vector contract shared with the
[`viamin/color_matching`](https://github.com/viamin/color_matching) backend.
`SolverParityCorpusTests` replays every scenario through
`WeightedSquaredErrorScorer` and asserts the per-candidate result, selected
index, selected color, error, and tie evidence exactly.

The corpus is generated and owned by the backend at
`priv/parity/v1/corpus.json`. It covers earliest-index tie-breaking,
positive-weight missing-measurement exclusion, zero-weight channels, and
channel weighting.

## Refreshing the fixture

1. Update the backend checkout to the revision that changes the solver
   contract.
2. In `viamin/color_matching`, run `mix parity.generate`; CI there also
   supports `mix parity.generate --check` to verify deterministic bytes.
3. Copy its `priv/parity/v1/corpus.json` over the Swift fixture, preserving
   the versioned directory, then run `swift test` from `ColorComposerCore`.
4. Review both repositories together. A changed algorithm version or any
   expectation requires explicit solver-contract review rather than silently
   accepting regenerated values.

The fixture is intentionally versioned. When backend semantics change, add a
new version directory and update the Swift replay test deliberately; do not
overwrite a prior contract without review.
