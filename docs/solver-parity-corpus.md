# Solver parity corpus

`ColorComposerCoreTests/SolverParityCorpusTests.swift` replays the committed
`ColorMatching.WeightedSquaredError` golden vectors from the backend repository.
The vendored fixture is
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`.

Refresh it only when the backend corpus intentionally changes:

1. Fetch `viamin/color_matching`'s `priv/parity/v1/corpus.json` from the reviewed
   backend revision.
2. Replace the vendored fixture byte-for-byte and record that source revision in
   the pull request.
3. Run `cd ColorComposerCore && swift test --filter SolverParityCorpusTests`.

The replay checks each candidate score, missing-measurement exclusions, the
selected candidate and error, and earliest-index tie breaking. A changed
`algorithm_version` is a compatibility event: inspect the backend solver change
before accepting the new fixture.
