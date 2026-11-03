# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`
is the committed copy of the backend solver-parity contract. It is sourced
verbatim from `viamin/color_matching` at
`priv/parity/v1/corpus.json` (introduced by upstream issue #111).

The permanent `SolverParityCorpusTests` test decodes the fixture and replays
every vector through `WeightedSquaredErrorScorer` and `CompositionSolver`. It
checks scores, exclusions, selected palette index and hex color, error, and
the explicit earliest-index tie evidence.

To refresh the fixture after a backend corpus version changes:

1. In `viamin/color_matching`, run `mix parity.generate` and commit the
   generated `priv/parity/v<version>/corpus.json` after its own checks pass.
2. Copy that file verbatim into the matching `Fixtures/` path here and update
   the test fixture name/version assertion if the algorithm version changed.
3. Run `cd ColorComposerCore && swift test --filter SolverParityCorpusTests`.

Do not hand-edit golden expectations. A change in scores, exclusions, weights,
or tie handling is a coupled solver-contract change and requires coordinated
review of both repositories.
