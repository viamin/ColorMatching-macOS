# Solver parity corpus

`ColorComposerCore` replays the server-owned golden corpus in
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/WeightedSquaredErrorParity/corpus.json`.
It was copied from `viamin/color_matching` at
`priv/parity/v1/corpus.json` (algorithm version 1, commit
`47057afd58f7d46b4d740ca7d2d08947774471`).

The permanent `WeightedSquaredErrorParityCorpusTests` suite checks every
recorded per-candidate score, exclusion, winning index, error, and earliest
wins tie result against `WeightedSquaredErrorScorer` and `CompositionSolver`.

To refresh the fixture after a server solver change:

1. In `viamin/color_matching`, run `mix parity.generate` and commit the
   resulting `priv/parity/v1/corpus.json` after its `mix parity.generate --check`
   verification passes.
2. Copy that byte-for-byte JSON file into this repository's fixture path.
3. Run `cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityCorpusTests`.
4. Review any changed algorithm version, scores, exclusions, weights, and tie
   expectations before updating the client solver.
