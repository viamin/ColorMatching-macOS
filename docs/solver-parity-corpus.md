# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/color_matching_solver_parity_v1.json`
is a verbatim copy of the version 1 solver corpus published by
[`viamin/color_matching`](https://github.com/viamin/color_matching) at
`priv/parity/v1/corpus.json` (issue [#111](https://github.com/viamin/color_matching/issues/111)).

The permanent `SolverParityCorpusTests` suite decodes the corpus and verifies
each candidate score, missing-measurement exclusion, tie outcome, selected hex
color, and selected index against `WeightedSquaredErrorScorer`.

To refresh the fixture after the backend publishes a new corpus version:

1. Download the matching `priv/parity/vN/corpus.json` from the backend's
   default branch without reformatting it.
2. Save it as `color_matching_solver_parity_vN.json` under the test Fixtures
   directory.
3. Update the corpus test's fixture path and expected `algorithm_version`.
4. Run `cd ColorComposerCore && swift test --filter SolverParityCorpusTests`.

The implementation-phase change must link this note from the repository README;
this test-authoring run may only modify test paths and `docs/`.
