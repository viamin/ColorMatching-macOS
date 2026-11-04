# Issue #39 verification plan

| Criterion | Smallest credible verification | Evidence status in this test-writing run |
| --- | --- | --- |
| Generated OpenAPI client handles the used `/api/v1` endpoints | Focused request/response contract test plus package/dependency inspection in implementation review | `PaletteAPIClientTests.testFetchColorsUsesVersionedEndpointAndProfileQuery`; generated-client inspection pending implementation |
| Per-server/profile cache and offline fallback remain intact | Existing focused disk-cache tests; implementation run must add an app-level fallback test if the migration crosses `ColorCatalog` | `ProfileColorCacheTests.testTwoServersKeepSeparateEntriesForTheSameProfileID`; UI badge and cached-profile fallback require inspectable app-level evidence |
| Solver selections match the committed corpus, including ties | Permanent corpus-driven unit test of the public solver selection path | `WeightedSquaredErrorParityCorpusTests.testSelectionsMatchCommittedParityCorpus` (not run: Swift toolchain unavailable) |
| Corpus consumption is documented | README review after the implementation phase, which is allowed to modify the README | Pending: this test-writing phase may only modify test paths and `docs/` |
| PR notes record migration and parity findings | Inspect the final PR description | Pending human/external evidence |

The parity fixture is intentionally committed with its test. At this run's
timestamp, the requested upstream PR endpoint was unavailable (HTTP 404), so
an implementation follow-up must import the exact `color_matching#111` corpus
before calling the criterion passed.
