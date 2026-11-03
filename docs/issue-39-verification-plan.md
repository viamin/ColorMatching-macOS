# Issue #39 verification plan

| Criterion | Smallest credible verification | Planned evidence |
| --- | --- | --- |
| Generated OpenAPI client serves existing palette endpoints | Focused client integration test with a mocked transport, asserting typed profile and color responses decode through the generated client. | `PaletteAPIClientTests` (implementation phase) |
| Disk cache and offline fallback remain unchanged | Existing cache tests plus a focused mocked-network test covering stale colors and cached-profile fallback. | `ProfileColorCacheTests` and `ColorCatalog` behavior tests (implementation phase) |
| Solver stays in parity with `color_matching` | Permanent unit/service test replays the committed backend corpus, checking each score, exclusion, selected index/error, and ties. | `SolverParityCorpusTests` |
| Corpus consumption is documented | Inspect the README for the upstream corpus URL, vendored location, and refresh command. | README update (implementation phase) |

The permanent parity fixture is copied from `viamin/color_matching` at
`priv/parity/v1/corpus.json`. Refresh it after running `mix parity.generate`
in that repository; its `algorithm_version` is an explicit compatibility
contract.
