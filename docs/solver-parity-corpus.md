# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`
is the committed copy of the upstream `color_matching` golden-vector corpus at
[`priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).

`SolverParityCorpusTests` decodes the fixture and verifies the weighted
squared-error score of every candidate plus the `CompositionSolver` selection
for each scenario. This includes earliest-wins ties, missing-measurement
exclusions, and zero-weight channels.

When the upstream solver's `algorithm_version` changes, regenerate its corpus
with `mix parity.generate`, copy the resulting `priv/parity/v1/corpus.json`
into this fixture path, and update the test's asserted version if required.
Run `swift test` in `ColorComposerCore` before committing the refresh.
