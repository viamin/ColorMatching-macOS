# Solver parity corpus

ColorComposerCoreTests replays the committed weighted_squared_error_v1.json
fixture against WeightedSquaredErrorScorer and CompositionSolver.

The canonical corpus is maintained in viamin/color_matching at
priv/parity/v1/corpus.json. Refresh this fixture after the server changes its
solver contract:

1. In the server repository, run mix parity.generate and commit the generated
   corpus after its own tests pass.
2. Copy that committed corpus to
   ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json.
3. Run cd ColorComposerCore && swift test --filter SolverParityCorpusTests.

The fixture intentionally covers exact ties (earliest index wins), missing
positive-weight measurements (excluded), zero-weight channels (ignored), and
per-channel weighting.
