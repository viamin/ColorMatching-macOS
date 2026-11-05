# Issue #39 verification plan

This red-phase change adds the tests and fixture needed before the generated-client implementation lands. The fixture is an unmodified copy of [`viamin/color_matching` `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json) at blob `70e9999065c81334d1f2b5038a96c67cfd5d59d1`.

| Criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Generated typed OpenAPI client is adopted | `OpenAPIClientManifestTests.testPackageDeclaresOpenAPIGeneratorAndRuntimeDependencies` checks the core package declares both required OpenAPI packages. The implementation phase must add operation-level request tests after generation. | Expected red: neither dependency is declared. |
| Per-server/profile disk cache stays isolated | Existing `ProfileColorCacheTests` cover read/write round trips, same-profile separation across servers, normalization, and cached-profile discovery. | Existing permanent unit coverage. |
| Offline-stale and cached-profile fallback stay intact | Existing cache tests preserve the data needed by the UI fallback; implementation phase must run the affected app integration tests because badge presentation is outside the core package. | Not run in this test-only phase. |
| Solver matches server corpus exactly | `WeightedSquaredErrorParityTests.testV1CorpusMatchesScoresAndSelections` replays every v1 scenario through both the scorer and solver, including ties, exclusions, zero weights, unknown weights, and all-excluded cases. | Expected to pass once Swift is available. |
| Corpus consumption is documented | Implementation phase must add the refresh instructions to `README.md`; this phase retains the exact upstream source and blob above for reproducibility. | Deferred by test-writing boundary. |

## Refreshing the fixture

When upstream publishes a new corpus version, download its committed JSON into `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/`, retain the version in the filename, and update the parity test only when the schema changes. Review the upstream blob ID and inspect `swift test` output before committing. Do not rewrite expected results locally: the server corpus is the contract.
