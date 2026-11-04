# Issue #39 verification plan

This test-writing change maps each acceptance criterion to the smallest
credible verification. The implementation run must update the result fields
below after it lands the generated client and vendors the upstream artifacts.

| Criterion | Verification | Current result |
| --- | --- | --- |
| Generated OpenAPI client replaces or wraps manual `/api/v1` transport | Focused `PaletteAPIClient` request/response contract tests, plus package-manifest review | Not run: upstream OpenAPI document from `viamin/color_matching#110` is unavailable to this checkout. |
| Per-server/profile cache, offline-stale badges, and cached-profile fallback remain intact | Existing focused cache tests and app-level inspection of `ColorCatalog` state | Not run in this test-writing phase; existing cache coverage is in `ProfileColorCacheTests`. |
| Solver selections exactly match the committed parity corpus, including ties | Permanent unit test: `WeightedSquaredErrorParityCorpusTests.testCorpusSelectionsMatchExpectedOutputsExactly` | Pending upstream corpus replacement from `viamin/color_matching#111`. |
| Corpus location and refresh procedure documented | README review | Not run: this phase permits LID docs and tests only; the implementation phase must update `README.md`. |
| PR notes generated-client migration, API shape findings, and parity results | Human review of PR description | Not run: PR creation is outside this checkout. |

## Corpus refresh procedure

The committed fixture lives at
`ColorComposerCore/Tests/ColorComposerCoreTests/Resources/weighted_squared_error_parity_corpus.json`.
When `viamin/color_matching#111` is available, replace that file verbatim with
the upstream corpus, retain its source revision in this document and the PR
description, and run:

```bash
cd ColorComposerCore
swift test --filter WeightedSquaredErrorParityCorpusTests
```

The harness intentionally asserts the selected palette ID and excluded-candidate
count for every case. It therefore covers the server-selection contract, not
only score arithmetic. The current fixture is a bootstrap schema and must not
be represented as the upstream corpus until it has been replaced from #111.
