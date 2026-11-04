# Issue #39 verification plan

| Criterion | Smallest credible verification | Status in test-writing phase |
| --- | --- | --- |
| Generated OpenAPI client preserves `/api/v1` request behavior | Focused `PaletteAPIClientTests` request/response contract tests; inspect generated client configuration and migration in implementation review | Existing focused coverage; generated-client evidence is pending implementation |
| Per-server/profile cache and offline-stale/profile fallbacks remain intact | Focused `ProfileColorCacheTests` plus inspect the UI/cache integration after the generated-client migration | Existing focused coverage; integration review is pending implementation |
| Solver matches the committed parity corpus, including ties | Permanent fixture-driven `WeightedSquaredErrorParityCorpusTests` | Added in this change |
| Corpus consumption is documented | Inspect the parity-corpus documentation and refresh procedure | Added in this change |
| PR records migration findings and parity results | Human review of the PR description | Not automatable |
