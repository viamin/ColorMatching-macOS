# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`
is the committed copy of the server-owned golden vectors from
[`viamin/color_matching`](https://github.com/viamin/color_matching),
`priv/parity/v1/corpus.json`. The fixture is currently sourced from commit
`47057afd58f7d46b4d4b740ca7d2d08947774471`.

`SolverParityCorpusTests` decodes every scenario and verifies the complete
score table, missing-measurement exclusions, selected palette entry, selected
error, and earliest-index tie breaking through both
`WeightedSquaredErrorScorer` and the non-dithered `CompositionSolver`.

When the server changes the corpus algorithm version, regenerate it there with
`mix parity.generate`, review the server fixture, replace the committed Swift
fixture with that exact file, and run `cd ColorComposerCore && swift test`.
The server additionally verifies its corpus with `mix parity.generate --check`.

This document is intentionally temporary handoff documentation for the
test-writing phase. The implementation phase must add the same refresh guidance
to the root README as required by issue #39.
