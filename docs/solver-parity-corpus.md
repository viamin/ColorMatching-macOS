# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity_corpus.json`
is the committed compatibility corpus for the `WeightedSquaredError` solver. The
authoritative source is [viamin/color_matching#111](https://github.com/viamin/color_matching/pull/111), and
`WeightedSquaredErrorParityCorpusTests` exercises it on every `swift test` run.

The upstream pull request was unavailable to this test-writing environment
(GitHub returned 404), so the initial fixture is a provisional compatibility
harness. Replace it verbatim with the published upstream corpus before the
implementation PR is approved.

To refresh it, download the published corpus from that pull request, replace the
fixture without changing case order or expected values, and run:

```bash
cd ColorComposerCore
swift test --filter WeightedSquaredErrorParityCorpusTests
```

Review the resulting diff for solver-policy changes. In particular, preserve
expected selection IDs for ties, excluded candidates, and zero or non-zero
channel weights; these are compatibility behavior, not test implementation
details.
