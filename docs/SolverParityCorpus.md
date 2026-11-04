# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`
is the committed input to `SolverParityCorpusTests`. It is a data-only contract
test for the selection behavior shared with the `color_matching` backend:
weighted squared error, missing-active-channel exclusion, zero-weight handling,
and earliest-candidate tie-breaking.

The authoritative corpus is owned by
[`viamin/color_matching` PR #111](https://github.com/viamin/color_matching/pull/111),
at `priv/solver_parity/weighted_squared_error.json`. Refresh it by copying the
upstream file verbatim over the fixture, preserving its schema and source
metadata, then run:

```bash
cd ColorComposerCore
swift test --filter SolverParityCorpusTests
```

This test-writing PR includes the harness and a representative fixture because
the upstream private PR was not readable from the isolated CI environment. The
implementation PR must replace the fixture with the upstream committed corpus
before it is merged.
