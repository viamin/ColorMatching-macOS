# Issue #39 verification plan

This test-writing change establishes the acceptance-criterion coverage before
the generated-client migration is implemented.

| Criterion | Smallest credible verification | Status in this change |
| --- | --- | --- |
| Typed OpenAPI client migrates `PaletteAPIClient` | Existing `PaletteAPIClientTests` remain the request/response contract regression suite; implementation review must inspect the generated client and wrapper. | Pending implementation |
| Per-server/profile cache and offline fallback remain intact | `ProfileColorCacheTests` cover server/profile isolation; `ColorCatalog` integration behavior requires macOS-app verification in the implementation PR. | Pending implementation |
| Solver follows the committed parity corpus, including ties | `WeightedSquaredErrorParityCorpusTests.testSolverSelectionsMatchCommittedParityCorpus` loads the committed JSON fixture and asserts selection, error, and exclusions for every case. | Passing locally |
| Corpus consumption is documented in the README | Update `README.md` during the implementation phase; the current test-writing hook deliberately permits only `docs/` documentation. | Pending implementation |
| PR description records migration/parity findings | Human-inspectable PR evidence, after the upstream #110/#111 artifacts are accessible. | Pending external evidence |

## Corpus refresh procedure

The canonical corpus is owned by
[`viamin/color_matching` PR #111](https://github.com/viamin/color_matching/pull/111).
When its published fixture changes, replace
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity_corpus.json`
without changing test semantics, then run:

```bash
cd ColorComposerCore
swift test --filter WeightedSquaredErrorParityCorpusTests
```

The fixture is intentionally read from disk by the test so a changed corpus is
always exercised. It captures exact selected color IDs, scores, exclusions,
zero-weight handling, and earliest-candidate tie handling.
