# Issue #39 verification plan

This is the test-writing (red) phase for “Adopt generated OpenAPI client and
enforce solver parity with the parity corpus.” The implementation run must
replace the provisional fixture below with the exact committed artifact from
`viamin/color_matching#111`; that upstream pull request was not accessible
from this environment on 2026-11-04.

| Criterion | Smallest credible verification | Current evidence |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` | `OpenAPIGeneratedClientDependencyTests.testPackageDeclaresSwiftOpenAPIGeneratorAndRuntime` asserts the SwiftPM package declares both required Apple packages. Existing `PaletteAPIClientTests` exercise authorization and the `/api/v1/printer_profiles` request. | Intentionally red until implementation adds the dependencies and generated client. |
| Per-server/profile cache, offline-stale state, and cached-profile fallback remain intact | Existing `ProfileColorCacheTests` cover server/profile namespacing and durable cache reads; implementation must add or retain an app-layer test for stale badge and fallback selection because it is a user-visible behavior. | Existing focused cache tests; app-layer fallback still needs implementation-run evidence. |
| Solver selections match the corpus, including ties, exclusions, and weights | `WeightedSquaredErrorParityCorpusTests.testWeightedSquaredErrorSelectionsMatchParityCorpus` loads the committed fixture and checks selected palette ID, exclusion count, and score for every row. | Fixture is provisional pending the inaccessible upstream #111 corpus. |
| README documents corpus refresh | Human inspectable documentation update in `README.md`, naming the committed corpus path and refresh command/revision. | Deferred: test-writing constraints permit only `docs/` and test files. |
| PR description records migration, shape changes, and parity results | Human inspectable pull-request description. | Must be written by the implementation/PR run. |

## Corpus refresh procedure

1. Obtain the exact corpus revision merged by `viamin/color_matching#111`.
2. Replace `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity_corpus.json` verbatim, retaining it as a committed test fixture.
3. Update its `upstream.revision` to the upstream commit SHA and remove the
   provisional-publication note.
4. Run `cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityCorpusTests`.
5. Record the upstream SHA, case count, ties, exclusions, and weight handling
   in the PR description and README.
