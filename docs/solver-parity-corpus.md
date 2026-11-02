# Solver parity corpus

`ColorComposerCoreTests` consumes the v1 golden corpus at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`.
It is copied from `viamin/color_matching` at
`priv/parity/v1/corpus.json` and is replayed by
`WeightedSquaredErrorParityTests` against both the scorer and the
one-cell `CompositionSolver` path.

When the backend updates its solver corpus, run `mix parity.generate` in the
`color_matching` repository, review its committed JSON, copy it into this
repository's fixture path, and run `cd ColorComposerCore && swift test`.
The backend corpus's `algorithm_version` is deliberately asserted by the
macOS test; update that expectation only as part of the reviewed corpus
refresh.

## Verification plan for #39

| Criterion | Smallest credible verification |
| --- | --- |
| Typed OpenAPI client migration | Inspect generated source and run the existing mocked endpoint tests. |
| Disk cache and offline fallback | Run `ProfileColorCacheTests` and the app-level offline fallback test after the client migration. |
| Solver parity | Run `WeightedSquaredErrorParityTests`; it replays every committed scenario, including ties and exclusions. |
| Corpus refresh documentation | Review this document and the committed fixture path. |
| PR migration notes | Inspect the PR description against the generated-client diff and parity test output. |
