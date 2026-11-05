# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json`
is the committed copy of the `color_matching` server corpus at
`priv/parity/v1/corpus.json` (introduced by [viamin/color_matching#111](https://github.com/viamin/color_matching/issues/111)).

The permanent Swift test replays every scenario through
`WeightedSquaredErrorScorer`, checking each candidate score, exclusions,
earliest-index tie selection, tie evidence, and final error exactly.

## Refreshing

1. In `viamin/color_matching`, run `mix parity.generate --check`; regenerate
   with `mix parity.generate` if its solver changed.
2. Copy the resulting `priv/parity/v1/corpus.json` to the fixture path above
   without reformatting it.
3. Run `cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityCorpusTests`.
4. Update the fixture only alongside the upstream corpus version and describe
   changed tie, exclusion, or weighting semantics in the pull request.
