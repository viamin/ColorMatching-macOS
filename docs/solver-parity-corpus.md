# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`
is the committed v1 corpus consumed by `SolverParityCorpusTests`. It is copied
verbatim from
[`viamin/color_matching`'s `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).

Refresh it only after the server corpus has been regenerated and reviewed:

1. Download the upstream `priv/parity/v1/corpus.json` into the fixture path.
2. Verify its SHA-256 and review its `algorithm_version`, scenario IDs, and
   tie/exclusion coverage.
3. Run `swift test --package-path ColorComposerCore` and commit the fixture and
   test updates together.

The corpus is deliberately checked in so parity is reproducible offline. It
covers weighted scores, positive-weight missing-data exclusions, zero-weight
channels, unknown weights, exact matches, and earliest-index tie selection.
