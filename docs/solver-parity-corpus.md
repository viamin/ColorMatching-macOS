# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity_corpus.json`
is the committed selection corpus for the `color_matching` `WeightedSquaredError`
solver. `WeightedSquaredErrorParityCorpusTests` runs every case through the
production `CompositionSolver` and compares the selected palette ID exactly.

The corpus carries its upstream provenance (`viamin/color_matching#111`) in its
`source` object. It covers weighted selection, deterministic earliest-candidate
ties, candidate exclusion for a missing required measurement, zero-weight
channels, and the no-eligible-candidate result.

## Refreshing

When `viamin/color_matching#111` publishes a replacement corpus, copy the
published JSON into the fixture path above, retaining its provenance and schema
version. Keep expected selected IDs exact: do not recompute expected values in
Swift. Then run:

```bash
cd ColorComposerCore
swift test --filter WeightedSquaredErrorParityCorpusTests
```

If upstream changes the corpus schema, update the fixture decoder in
`WeightedSquaredErrorParityCorpusTests.swift` in the same change and record the
shape change and test result in the PR description.
