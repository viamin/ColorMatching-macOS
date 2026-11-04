# Weighted squared error parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`
is the committed cross-language contract harness for `WeightedSquaredErrorScorer`.
`WeightedSquaredErrorParityTests` loads every case and compares the selected
palette-color ID with the expected result, including ties, exclusions, and
zero/non-uniform channel weights.

## Refreshing the corpus

The canonical corpus is owned by
[`viamin/color_matching#111`](https://github.com/viamin/color_matching/pull/111).
When that corpus changes, replace the committed JSON fixture with the upstream
version, preserve its source revision in this document or the fixture metadata,
and run:

```bash
cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityTests
```

This test-writing change contains representative contract cases because the
upstream private PR was unavailable from this environment. Before the
implementation PR merges, replace them with the exact upstream corpus and add
a README link to this document. Product and package files remain untouched in
this phase.
