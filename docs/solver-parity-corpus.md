# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityCorpusTests.swift`
loads the committed JSON fixture at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`.
It exercises the selection contract for the default solver, including
earliest-in-palette ties, missing active-channel exclusions, zero-weight
channels, and weighted trade-offs.

The fixture is the committed client-side corpus for the contract published by
[`viamin/color_matching#111`](https://github.com/viamin/color_matching/pull/111).
When the upstream corpus changes, replace this fixture with the upstream JSON
and keep its expected selections unchanged, then run:

```bash
cd ColorComposerCore
swift test --filter WeightedSquaredErrorParityCorpusTests
```

Keep the fixture schema and this test synchronized with the upstream corpus.
The implementation run must add the required README link; this tests-only run
cannot edit the root README.
