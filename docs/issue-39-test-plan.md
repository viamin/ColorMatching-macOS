# Issue #39 verification plan

This tests-only change establishes the smallest credible verification for each
acceptance criterion before implementation begins.

| Criterion | Verification | Evidence at implementation PR head |
| --- | --- | --- |
| Generated `/api/v1` client replaces handwritten transport | Focused client contract tests using a mocked `URLProtocol`; assert generated operations, authentication, and published response shapes | `PaletteAPIClientTests.swift` results |
| Per-server/profile caching and offline fallbacks stay intact | Permanent service tests cover server scoping, stale color fallback, and cached-profile fallback | `ProfileColorCacheTests.swift` and catalog tests results |
| Solver matches server behavior | Permanent corpus-replay test decodes the committed upstream corpus and checks each candidate score, selection, error, exclusion, and tie result | `SolverParityCorpusTests.swift` result |
| README explains corpus refresh | Inspect the README change against the upstream corpus URL and pinned refresh command | Reviewer inspection |
| PR records migration and parity findings | Inspect the PR description for API-shape differences, generated-client notes, and results covering ties, exclusions, and weights | Reviewer inspection |

## Red-phase state

`SolverParityCorpusTests` intentionally expects the committed fixture at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json`.
The implementation phase must vendor the byte-for-byte corpus from
[`viamin/color_matching` `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json), then run the suite. Refreshes should replace that fixture only after reviewing the upstream `algorithm_version` and updating the harness deliberately for a version change.
