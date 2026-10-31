# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`
is the committed copy of the version 1 solver corpus published by
[`viamin/color_matching`](https://github.com/viamin/color_matching) at
`priv/parity/v1/corpus.json`. `ParityCorpusTests` loads it on every core test
run and verifies weighted scores, exclusions, winning candidates, and
earliest-index tie behavior.

To refresh the fixture after the backend publishes a new corpus version:

1. Fetch the corresponding committed `priv/parity/vN/corpus.json` source
   from `viamin/color_matching`.
2. Replace the fixture with that file, retaining its version in the local
   filename.
3. Update `ParityCorpusTests` to assert the new `algorithm_version` and run
   `swift test` from `ColorComposerCore`.

Do not edit expected scores by hand: the backend corpus is the shared source
of truth. A scorer-semantic change requires a new corpus version and matching
client implementation review.
