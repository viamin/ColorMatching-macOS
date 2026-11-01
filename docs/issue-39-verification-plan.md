# Issue #39 verification plan

| Criterion | Smallest credible verification | Phase |
| --- | --- | --- |
| Generated OpenAPI client migrates palette requests | Focused `PaletteAPIClient` contract tests cover profiles, colors, authorization, response decoding, and typed failures against an in-process URL protocol. | Implementation |
| Disk cache and offline fallbacks remain unchanged | Existing `ProfileColorCacheTests` remain the focused regression coverage; implementation must run them after routing API data through the generated client. | Implementation |
| Solver matches server selections | `SolverParityCorpusTests` replays the committed server corpus through both the scorer and one-cell solver path, including tie, exclusion, and weight cases. | Tests |
| Corpus consumption is documented | README links to upstream corpus and specifies the refresh procedure. | Tests |
| PR records migration and parity findings | Inspectable PR description, including API shape changes and parity results. | Human/external evidence |

The parity fixture is copied byte-for-byte from `viamin/color_matching` commit `a82aec5441d2a7b0100e8c8ab81d573e11ace9b0`, `priv/parity/v1/corpus.json`.
