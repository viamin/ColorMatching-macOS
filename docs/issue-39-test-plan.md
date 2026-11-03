# Issue #39 test plan

## Criterion map

| Criterion | Smallest credible verification | Status in test-writing phase |
| --- | --- | --- |
| Generated OpenAPI client is linked to `ColorComposerCore` | `GeneratedOpenAPIClientContractTests.testOpenAPIRuntimeIsLinkedToTheCorePackage` | Red: `swift-openapi-runtime` is not yet linked. |
| Palette/profile behavior stays compatible | Existing cache unit coverage plus `PaletteAPIClientTests`; implementation phase must run the client/cache tests after migration. | Not run in this phase. |
| Solver selections match the corpus, including ties | `WeightedSquaredErrorParityCorpusTests.testSelectionsMatchTheCommittedParityCorpus` loads `Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`. | Passing before migration; replace this fixture with the exact upstream corpus before merge. |
| Corpus consumption is documented | This document and the README update planned for implementation phase. | This document is committed; README is outside the tests-only allowlist. |

## Corpus refresh

The committed corpus belongs at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`.
Refresh it by downloading the canonical `WeightedSquaredError` corpus from
[`viamin/color_matching#111`](https://github.com/viamin/color_matching/pull/111),
replacing that file without changing its cases, then run:

```bash
cd ColorComposerCore
swift test --filter WeightedSquaredErrorParityCorpusTests
```

The isolated test-writing environment cannot access that private upstream PR;
the implementation phase must replace the seed fixture with the exact published
artifact and record its revision in the PR description.
