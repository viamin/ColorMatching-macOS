# Issue #39 verification plan

This is the tests-only phase. The implementation phase must retain these checks and
record their actual results in the pull request description.

| Criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Generated OpenAPI client replaces the hand-written `/api/v1` transport | Focused `PaletteAPIClient` unit tests using a URL protocol: generated operations request the existing printer-profile and colors paths, preserve bearer-token handling, and decode the published shapes. Inspect `Package.swift`, generated sources, and the checked-in OpenAPI document. | Not run — implementation artifact does not exist yet. |
| Per-server/profile disk cache behavior is retained | Existing `ProfileColorCacheTests` cover server namespaces and profile entries. Add a focused catalog/service test that proves a failed network refresh returns cached colors and marks them offline-stale. | Not run — this package does not currently expose the catalog orchestration to a core test target. |
| Cached profile fallback is retained | A focused catalog/service test simulates profile endpoint failure after a cached profile fetch and asserts cached profiles are returned. | Not run — implementation phase test. |
| Solver selections match the parity corpus, including ties, exclusions, and weights | `SolverParityCorpusTests.testWeightedSquaredErrorSelectionsMatchParityCorpus` solves each one-cell corpus vector and asserts selected ID, score/unmatched result, and exclusion count. | Harness added; upstream corpus cannot be fetched in this environment. |
| Corpus consumption is documented | README documents the committed fixture location, upstream `viamin/color_matching#111`, and a deliberate refresh procedure. | Not run — README is outside this phase's permitted LID allowlist. |
| Generated client and parity test are green | Run `swift test` in `ColorComposerCore`. | Not run — Swift is absent from the environment. |

## Parity-corpus provenance

The committed fixture is at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`.
It is intentionally marked `provisional`: the source repository returned HTTP 404 for
the referenced PR during this run. Before implementation is declared complete, replace
the fixture with the exact corpus committed by `viamin/color_matching#111`, preserve
its upstream revision/checksum in fixture metadata, and run the corpus test without
altering expectations.

## Required PR evidence

The implementation PR description must state:

- the generated-client migration approach and the generated source/spec revision;
- any observed `/api/v1` schema differences from the former DTOs;
- the `swift test` command and parity-case result count;
- explicit findings for earliest-wins ties, missing-active-channel exclusions, and
  positive/zero weight handling; and
- evidence that server/profile-scoped cache entries, offline-stale status, and cached
  profile fallback remain unchanged.
