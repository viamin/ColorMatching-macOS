# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`
is the committed copy of the server's deterministic solver corpus from
[`viamin/color_matching`](https://github.com/viamin/color_matching/tree/main/priv/parity/v1).
`SolverParityCorpusTests` replays every scenario through
`WeightedSquaredErrorScorer` and the default `CompositionSolver`, including
per-candidate scores, exclusions, selected index, selected color, error, and
earliest-wins tie evidence.

When the server changes its solver contract, run `mix parity.generate` in the
`color_matching` repository, review the new `priv/parity/v1/corpus.json`, then
replace this fixture byte-for-byte and update the expected `algorithm_version`
assertion if the server bumped it. Run `cd ColorComposerCore && swift test`
before committing the refreshed fixture.
