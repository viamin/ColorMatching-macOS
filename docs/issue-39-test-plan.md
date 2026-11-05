# Issue #39 verification plan

This is the tests-only phase for the generated OpenAPI client and solver parity work.

| Criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Generated OpenAPI client is declared | `OpenAPIClientMigrationContractTests.testPackageDeclaresGeneratedOpenAPIClientDependencies` asserts the package manifest declares generator/runtime dependencies and generated-client integration symbols. | Red until implementation |
| Existing cache/offline behavior remains intact | Existing focused `ProfileColorCacheTests` and `PaletteAPIClientTests`; implementation phase must run them after migration. | Not rerun in this phase |
| Solver matches parity corpus | `WeightedSquaredErrorParityTests.testSelectionsMatchCommittedColorMatchingCorpus` loads the committed JSON corpus and checks selected ID, error, and exclusions, including ties. | Expected green |
| Corpus consumption documented | Update `README.md` with the corpus location and refresh procedure. | Deferred: README is outside the tests-only allowlist |

The corpus fixture is at `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`. Refresh it from `viamin/color_matching#111` while preserving the source identifier and the tie/exclusion/weight cases.
