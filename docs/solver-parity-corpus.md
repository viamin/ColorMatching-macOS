# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json`
is the committed copy of the backend's deterministic solver corpus from
[`viamin/color_matching`](https://github.com/viamin/color_matching/tree/main/priv/parity/v1).
`SolverParityCorpusTests` decodes it and compares every score, exclusion, selected
candidate, expected error, and earliest-wins tie result against
`WeightedSquaredErrorScorer`.

Refresh it after a backend corpus version changes:

```bash
curl -L https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

Check the upstream `algorithm_version` before replacing the fixture. A version
bump means scorer semantics may have changed and needs explicit review; do not
silently overwrite the existing corpus.
