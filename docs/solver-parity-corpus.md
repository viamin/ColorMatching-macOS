# Solver parity corpus

`ColorComposerCoreTests` replays the versioned corpus committed by the
[`viamin/color_matching`](https://github.com/viamin/color_matching) service at
`priv/parity/v1/corpus.json`. The copied fixture lives at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`.

When the service changes its solver contract, regenerate the server corpus with
`mix parity.generate`, copy the resulting versioned JSON into the matching Swift
test fixture, and run:

```bash
cd ColorComposerCore
swift test --filter SolverParityCorpusTests
```

The test asserts every candidate score, exclusion, selected palette index and
hex color, selected error, and declared tie indices. A new server
`algorithm_version` requires an intentional fixture and test update.
