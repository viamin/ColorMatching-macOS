# Issue #39 verification plan

This test-writing change maps each acceptance criterion to the smallest
credible verification. The implementation change must update this evidence
with the resulting test output and the exact imported upstream revisions.

| Criterion | Verification | Evidence at this head |
| --- | --- | --- |
| Generated OpenAPI client is adopted | Focused manifest contract test for runtime, generator, plugin, and generated target wiring. | `OpenAPIClientManifestContractTests.testCorePackageDeclaresGeneratedOpenAPIClient` (red until implementation) |
| Profile colors stay cache-scoped and available offline with a stale indication | Existing focused cache tests cover per-server/profile storage; the app-level catalog behavior needs a permanent system test in the implementation run because it owns the offline badge and fallback policy. | `ProfileColorCacheTests` server-scoping tests; system test not yet present |
| Solver matches the committed parity corpus, including ties | Data-driven focused solver test reads `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json` and asserts selected IDs, excluded IDs, and scores. | `SolverParityCorpusTests.testWeightedSquaredErrorSelectionsMatchParityCorpus` |
| README tells maintainers how to refresh the corpus | Human inspection of the README after the implementation run. This red-phase run may only change tests and LID docs. | not yet run |
| PR description records migration and parity findings | Human/external inspection of the PR body after implementation. | not yet run |

## Corpus refresh

The committed consumer fixture is deliberately read directly from the test
target so it remains visible in review and cannot silently disappear from a
release build. When `viamin/color_matching#111` is available to this checkout,
replace it byte-for-byte with that PR's published corpus, retain its upstream
revision in the fixture metadata, and run `swift test` from
`ColorComposerCore`.

The upstream PR endpoints were inaccessible from this run (the GitHub proxy
returned `Repository mismatch`), so this fixture records the required consumer
schema and the known parity edge cases but is not represented as a verified
copy of the upstream corpus.
