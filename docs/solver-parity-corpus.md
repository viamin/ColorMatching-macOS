# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`
is an exact committed copy of the server corpus from
`viamin/color_matching` at `priv/parity/v1/corpus.json`. The permanent
`SolverParityCorpusTests` suite decodes every scenario and verifies each
candidate score, selection, error, exclusion, and earliest-index tie result.

To refresh it after the server changes the corpus, download the versioned
fixture from the server repository, replace the committed JSON file without
rewriting it, and run `cd ColorComposerCore && swift test --filter
SolverParityCorpusTests`. Review an `algorithm_version` change as a solver
contract change rather than an ordinary fixture update.

## Criterion verification plan

| Criterion | Smallest credible verification |
| --- | --- |
| Generated client and API migration | Focused `PaletteAPIClient` contract tests added during implementation, plus `swift test`. |
| Disk cache and offline fallback remain intact | Existing focused cache/client tests, extended only where generated-client integration alters the request seam. |
| Solver parity, including ties and exclusions | Permanent `SolverParityCorpusTests` against every server-provided corpus scenario. |
| Corpus consumption documentation | This refresh procedure, followed by README linking during implementation. |
| PR migration findings | Human review of the implementation PR description against the published OpenAPI document. |
