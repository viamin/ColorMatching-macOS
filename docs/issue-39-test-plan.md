# Issue #39 verification plan

This test-writing change maps each acceptance criterion to its smallest
credible verification. The implementation phase must update the result column
with the command output and any external evidence at the resulting PR head.

| Criterion | Verification | Result in this test phase |
| --- | --- | --- |
| Generated OpenAPI client is used by `PaletteAPIClient` | Focused `PaletteAPIClientTests` request/response contract tests against the committed OpenAPI fixture, plus a package dependency/build inspection | Not run — requires implementation and committed spec fixture |
| Per-server/profile disk cache, offline-stale badge, and cached-profile fallback remain intact | Existing permanent unit tests in `ProfileColorCacheTests.swift`; an app-level human inspection of the offline-stale badge remains required | Not run — existing coverage must be rerun after migration; badge is human-visible evidence |
| Solver selections exactly match the parity corpus, including ties | Permanent `SolverParityCorpusTests.testWeightedSquaredErrorScorerExactlyReplaysCommittedParityCorpus` | Pending execution |
| Corpus consumption is documented in the README | README review after implementation; source and refresh command must cite `viamin/color_matching` `priv/parity/v1/corpus.json` and `mix parity.generate` | Not run — README is outside the test-writing allowlist |
| PR describes migration, API-shape findings, and parity results | PR-body review with links to package diff, generated source/spec, and parity-test output | Not run — external/human evidence |

The committed fixture is copied byte-for-byte from
`viamin/color_matching` PR #111 at `priv/parity/v1/corpus.json`. Refresh it by
obtaining the upstream committed fixture after running `mix parity.generate`
there, copying it to
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/Parity/v1/corpus.json`,
and rerunning the permanent parity test.
