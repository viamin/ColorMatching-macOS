# Issue #39 verification plan

| Criterion | Verification | Status in test-writing phase |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` | Focused API-client tests for the generated wrapper plus cache/offline regression tests | Deferred: package and production-source edits are prohibited in this phase. |
| Per-server/profile cache, offline-stale badge, cached-profile fallback remain intact | Existing `ProfileColorCacheTests` and `PaletteAPIClientTests`, augmented in implementation if generated-client integration changes behavior | Deferred to implementation phase. |
| Solver matches the server parity corpus | Permanent unit test replays the committed v1 corpus, including score tables, exclusions, weights, selections, and exact ties | `WeightedSquaredErrorParityTests.testReplaysVersionOneServerParityCorpus` |
| README explains corpus refresh | Inspect `README.md` after documenting source and refresh command | Deferred: the test-writing allowlist permits `docs/`, not root README changes. |
| PR records client migration, shape findings, and parity results | Human inspection of PR description | Not automatable; deferred until a PR is opened. |

The corpus fixture is copied verbatim from `viamin/color_matching` at
`priv/parity/v1/corpus.json`. Refresh it from that path after the server bumps
`algorithm_version`; the parity test intentionally decodes unknown weight keys
but ignores them because this client supports the server's five known lighting
conditions only.
