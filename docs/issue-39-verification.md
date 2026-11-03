# Issue #39 verification plan

This test-writing change establishes the permanent regression harness for the
solver contract. The canonical corpus is owned by
[`viamin/color_matching#111`](https://github.com/viamin/color_matching/issues/111)
at `priv/parity/v1/corpus.json`. The committed fixture is an exact copy of the
upstream `main` blob `70e9999065c81334d1f2b5038a96c67cfd5d59d1`.

| Acceptance criterion | Smallest credible verification | Status in this test-writing change |
| --- | --- | --- |
| Typed generated `/api/v1` client replaces handwritten decoding | Focused `PaletteAPIClient` contract tests using generated-client operations, plus an inspectable generated source/spec artifact | Deferred: implementation files and package manifest are outside this run's allowlist. |
| Per-server/profile cache, offline-stale badge, cached-profile fallback are unchanged | Existing `ProfileColorCacheTests` plus a focused catalog-level fallback test | Existing disk-cache tests retain per-server/profile coverage; catalog integration test is deferred because app sources are outside this package test target. |
| Solver selection matches parity corpus, including ties | `SolverParityCorpusTests.testWeightedSquaredErrorMatchesCanonicalParityCorpus` replays every canonical scenario and asserts each score/exclusion, selected index, result error, and earliest-wins ties | Added. The 12 upstream cases cover ties, exclusions, zero weights, unknown weights, and all-excluded targets. |
| Corpus consumption is documented | README records upstream corpus location and a refresh command/process | Deferred: README is not in the documentation allowlist for this test-writing run. |
| PR records migration/parity findings | PR description cites the generated source/spec revision and the full parity test result | Deferred until the upstream corpus and OpenAPI PR are accessible. |

## Implementation handoff

The implementation run must add a dedicated `SolverParityTests` SwiftPM test
target and make this fixture a declared test resource (rather than relying on
`#filePath`). It must add `swift-openapi-generator` and `swift-openapi-runtime`,
then update the root README's **Palette data** section to point to the upstream
corpus and explain how to refresh this exact fixture.

The agent environment has no Swift toolchain. Neither a test name nor an
unrun broad suite is treated as evidence for an acceptance criterion.
