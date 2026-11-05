# Solver parity corpus

`WeightedSquaredErrorScorer` is verified against the committed v1 corpus from
[`viamin/color_matching`](https://github.com/viamin/color_matching/tree/main/priv/parity/v1).
The exact upstream fixture is stored at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/v1/corpus.json`.
`SolverParityCorpusTests` replays every candidate score and selection,
including exclusions, channel weights, and earliest-index tie-breaking.

To refresh, run `mix parity.generate` in `viamin/color_matching`, copy
`priv/parity/v<version>/corpus.json` into the matching fixture directory in
this repository, update the corpus-version assertion, and run
`cd ColorComposerCore && swift test`.

## Criterion verification plan

| Criterion | Smallest credible verification |
| --- | --- |
| Generated OpenAPI client migration | Focused `PaletteAPIClient` service tests exercise the generated transport through the public client, including versioned paths and authorization. |
| Disk cache and offline fallback | Existing `ProfileColorCacheTests` plus a focused service test for cached-profile fallback and offline-stale state. |
| Solver parity | Permanent unit test replays every committed upstream corpus scenario, its individual scores, selection, error, and tie evidence. |
| Corpus documentation | README review confirms source and refresh workflow after implementation promotes this note. |
| PR findings | Human review of the PR description records generated-client shape findings and parity results. |
