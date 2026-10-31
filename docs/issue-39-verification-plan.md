# Issue #39 verification plan

| Criterion | Smallest credible verification | Status in test-writing phase |
| --- | --- | --- |
| Generated typed `/api/v1` client preserves the client contract | Focused `PaletteAPIClientTests` request/response contract tests, run against the generated-client adapter in implementation | Not yet implemented |
| Per-server/profile disk cache, offline-stale badge, and cached-profile fallback remain intact | Existing focused `ProfileColorCacheTests` plus app-level UI review of the badge/fallback wiring | Existing unit coverage; UI evidence deferred to implementation PR |
| Solver selection has backend parity, including weights, exclusions, and ties | `SolverParityCorpusTests` loads the committed JSON corpus and asserts selected palette ID, error, and exclusions for each case | Added in this PR |
| Corpus consumption is documented | README section naming the upstream corpus and refresh command/revision | Deferred: this test-writing run may only commit `docs/` files, not `README.md` |
| Generated-client migration and parity findings are recorded | PR description with shape diffs, corpus revision, and test result | Deferred to implementation PR |

The upstream `viamin/color_matching#111` artifact is private/unavailable to this environment (GitHub returned 404 without repository credentials). The fixture establishes the expected consumer format and regression coverage; replace its contents with the exact upstream corpus before implementation is merged.
