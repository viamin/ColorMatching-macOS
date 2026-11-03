# Solver parity corpus

`ColorComposerCoreTests` consumes the versioned golden-vector corpus committed
by [`color_matching`](https://github.com/viamin/color_matching) at
`priv/parity/v1/corpus.json`. The checked-in copy is
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/SolverParity/v1/corpus.json`.

`SolverParityCorpusTests` replays every scenario through
`WeightedSquaredErrorScorer` and `CompositionSolver`. It checks every candidate
score, missing-measurement exclusion, selected palette index and hex color,
minimum error, and earliest-index tie breaking. Scenarios whose target is
missing an active channel are checked through the scorer because the solver
correctly requires a source grid for every active channel.

## Refreshing the fixture

1. In `color_matching`, run `mix parity.generate --check`; if the backend
   solver intentionally changed, run `mix parity.generate` and commit its
   reviewed corpus update.
2. Copy the resulting `priv/parity/v<algorithm_version>/corpus.json` into the
   matching `Fixtures/SolverParity/v<algorithm_version>/` directory here.
3. Update the parity test's expected algorithm version and run
   `cd ColorComposerCore && swift test --filter SolverParityCorpusTests`.

Treat a corpus version change as a coupled backend/client behavior change:
review ties, exclusions, and weights before updating the fixture.
