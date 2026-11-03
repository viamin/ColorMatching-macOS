# Solver parity corpus

`ColorComposerCoreTests` consumes the committed v1 fixture at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/Parity/v1/corpus.json`.
It is a pinned copy of the authoritative corpus in
[`viamin/color_matching`](https://github.com/viamin/color_matching) at
`priv/parity/v1/corpus.json`.

The parity test decodes every scenario and checks each candidate score, the
selected palette entry, its error, and the expected tied indices. This covers
positive-weight missing-measurement exclusions, zero-weight channels, channel
weights, and deterministic earliest-index tie breaking.

## Refreshing the fixture

After the backend intentionally changes its solver or increments
`algorithm_version`, regenerate the backend corpus with `mix parity.generate`.
Then replace the local fixture with the committed upstream output, review its
diff, and run:

```bash
cd ColorComposerCore
swift test --filter SolverParityCorpusTests
```

Do not hand-edit expected scores: the upstream corpus is the contract. A
corpus version change requires a matching review of solver semantics and this
consumer test.
