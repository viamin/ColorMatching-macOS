# Issue #39 verification plan

## Criterion coverage

| Criterion | Smallest credible verification | Status in test-writing phase |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` | Existing `PaletteAPIClientTests` contract tests, plus package/dependency inspection after implementation | Not run: production and package edits are prohibited in this phase. |
| Per-server/profile cache and offline fallback remain intact | Focused `ProfileColorCacheTests`; app-level offline badge remains human-visible behavior to inspect after implementation | Existing cache tests pass; badge inspection deferred. |
| Solver selections match the parity corpus, including ties | Permanent `WeightedSquaredErrorParityCorpusTests` loading the committed JSON fixture | Added in this phase. The exact upstream fixture must replace this bootstrap corpus once `viamin/color_matching#111` is accessible. |
| README documents corpus consumption | Inspect `README.md` after implementation | Not run: README is outside the test-writing allowlist. |
| PR records migration and parity findings | Human/external PR inspection | Not run: no PR is opened in this run. |

## Corpus refresh procedure

The committed test fixture is `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`. When `viamin/color_matching#111` is available, copy its canonical corpus to that exact path without transforming case order or expected selections, then run:

```bash
cd ColorComposerCore
swift test --filter WeightedSquaredErrorParityCorpusTests
```

The test constructs a one-cell solve for every case and compares the selected palette color ID exactly. It therefore protects tie order, active-channel exclusions, and positive-weight handling without encoding a second solver implementation in the test.
