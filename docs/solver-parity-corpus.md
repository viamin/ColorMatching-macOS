# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`
is the committed parity fixture for `WeightedSquaredErrorScorer`. Its intended
source of truth is `viamin/color_matching#111`; that private/unavailable PR
returned 404 in this test-writing environment, so the fixture currently pins
the known contract cases and is marked pending import. The test reads the file
directly so every case exercises the public `CompositionSolver` selection path,
including its earliest-candidate tie rule.

When the upstream corpus is accessible (and whenever it changes), replace the
pending cases with its exact cases, preserving the upstream revision or PR
reference in the `source` field. Run:

```bash
cd ColorComposerCore
swift test --filter WeightedSquaredErrorParityCorpusTests
```

The corpus must cover weighted selection, zero-weight omissions, active-channel
exclusions, all-excluded palettes, and tie cases. Update the project README in
the implementation phase to link to this document and the upstream corpus.
