# Issue #39 verification plan

This is the tests-only phase. The implementation phase must retain this map in
its PR evidence and replace the `not_run` entries with results from its head.

| Criterion | Smallest credible verification | Phase status |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` | Focused HTTP contract tests for profiles, colors, bearer authorization, response decoding, and status mapping; inspect `Package.swift`, generated source, and the committed OpenAPI input. | not_run — implementation required |
| Cache and offline fallback behavior is unchanged | Existing `ProfileColorCacheTests` cover per-server/profile persistence and corrupt/missing cache handling; retain and run them. App-level stale-badge/profile-picker behavior requires a human UI check. | not_run — implementation required |
| Solver matches the upstream corpus | Permanent `SolverParityCorpusTests` decodes the vendored v1 corpus and verifies every score, exclusion, selected palette index/hex/error, and tie indices through the scorer and default solver. | planned |
| README explains corpus consumption | Inspect the README for the upstream path, pinned corpus location, and refresh procedure. | not_run — implementation required |
| PR records migration and parity findings | Inspect the PR description after implementation. | not_run — external evidence |

The fixture is copied byte-for-byte from
`viamin/color_matching@47057af` at `priv/parity/v1/corpus.json`. Refresh it by
copying the upstream committed corpus into
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity-v1-corpus.json`,
reviewing its schema/version diff, and running `swift test` from
`ColorComposerCore`.
