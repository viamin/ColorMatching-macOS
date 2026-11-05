# Issue #39 verification plan

| Criterion | Smallest credible verification | Red-phase status |
| --- | --- | --- |
| Generated OpenAPI client backs `PaletteAPIClient` | Focused client contract test using a URL protocol to assert the generated operation paths, query encoding, auth header, and decoded API response. | Deferred: the generated client and package dependency are implementation-phase work. |
| Disk cache and offline fallback stay intact | Existing focused cache tests cover server/profile isolation, stale colors, and cached-profile fallback; implementation must rerun these unchanged. | Existing coverage identified in `ProfileColorCacheTests`. |
| Solver remains in parity with `color_matching` | Permanent corpus-replay unit test checks every candidate score, exclusion, selected index, exact selected error, and tied indices. | Added in this change. |
| README explains corpus refresh | Inspect the committed README text and the upstream corpus generation command. | Deferred: this test-writing run permits LID docs but not root implementation/documentation files. |
| PR records API and parity findings | Inspectable PR description, based on the implementation diff and test output. | External/human evidence; deferred until the implementation PR is created. |

The committed fixture is copied byte-for-byte from
`viamin/color_matching` at `priv/parity/v1/corpus.json` (algorithm version 1).
It deliberately covers earliest-index tie selection, positive-weight missing
measurement exclusions, zero-weight missing channels, exact matches, and
mixed palettes. Refresh it from the backend with `mix parity.generate`, then
copy the resulting fixture here and run `cd ColorComposerCore && swift test`.
