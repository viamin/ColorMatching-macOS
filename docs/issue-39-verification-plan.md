# Issue #39 verification plan

| Criterion | Verification | Evidence after implementation |
| --- | --- | --- |
| Generated OpenAPI client migration | Focused package-contract test and API-client request/response tests | `GeneratedClientPackageTests` and `PaletteAPIClientTests` |
| Per-profile cache and offline fallback remain intact | Existing permanent service tests | `ProfileColorCacheTests` |
| Solver parity corpus | Permanent unit test replaying upstream golden vectors | `SolverParityCorpusTests` |
| Corpus refresh instructions | Human inspection of README | README corpus-consumption section |
| PR migration notes and parity findings | Human inspection of PR body | PR description |

The parity fixture is a representative red-phase subset derived from
`viamin/color_matching` issue #111, `priv/parity/v1/corpus.json`. The
implementation phase must replace it with the full byte-for-byte upstream
corpus. Refresh it by copying the upstream corpus into
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`,
then run `cd ColorComposerCore && swift test`.
