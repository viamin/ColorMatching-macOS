# Solver parity corpus

`ColorComposerCore` consumes the backend's committed v1 golden vectors at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json`.
The authoritative source is
[`viamin/color_matching` `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).

The parity test decodes every scenario and checks exact candidate scores,
exclusions, selected color, selected error, and earliest-index tie-breaking.

To refresh the fixture after the backend changes its solver:

1. In `viamin/color_matching`, run `mix parity.generate` and commit the reviewed corpus.
2. Copy that committed corpus into the fixture path above without transforming it.
3. Update the test's expected `algorithmVersion` only when the backend corpus version changes.
4. Run `cd ColorComposerCore && swift test`.

Treat an unexpected parity diff as a contract change: review the backend corpus
and solver change together before updating this fixture.
