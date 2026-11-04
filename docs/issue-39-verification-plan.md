# Issue #39 verification plan

| Criterion | Smallest credible verification | Status in tests-only phase |
| --- | --- | --- |
| Generated OpenAPI client migrates palette requests | Focused `PaletteAPIClient` HTTP contract tests for profiles, colors, auth, and non-2xx mapping; inspect generated client and package dependency at implementation review | Not yet runnable: generated target is implementation work |
| Cache and offline fallback stay intact | Existing focused disk-cache tests plus an app-catalog integration test that simulates an unavailable server and asserts cached profiles/colors and offline-stale state | Existing core cache coverage; catalog integration test deferred to implementation phase |
| Solver matches the server | Permanent corpus unit test loading the committed v1 fixture and asserting every score, selection, error, exclusion, and tie winner | Added in this change |
| README explains corpus refresh | Inspect the README section and validate its linked upstream path and refresh command | Deferred: this tests-only phase only permits test paths and LID docs |
| PR records migration and parity findings | Human review of the PR description against implementation diff and test output | Human/external evidence required |
