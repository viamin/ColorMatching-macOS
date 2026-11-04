# Solver parity corpus

`ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json` is the committed copy of the server-owned parity corpus from [`viamin/color_matching`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json). `WeightedSquaredErrorParityCorpusTests` decodes and replays every scenario through `WeightedSquaredErrorScorer`, checking every candidate score, earliest-wins selection, expected error, and tied indices.

## Refreshing

When the backend intentionally publishes a new corpus, download its committed `priv/parity/v1/corpus.json`, replace the local fixture byte-for-byte, and run:

```bash
cd ColorComposerCore
swift test --filter WeightedSquaredErrorParityCorpusTests
```

Review changes for solver semantics before updating the fixture. The current corpus explicitly covers exact and multi-way ties, exclusion when a positive-weight channel is missing, ignoring missing zero-weight channels, and unknown weight keys.

## Criterion verification plan

| Criterion | Smallest credible verification | Current phase |
| --- | --- | --- |
| Generated OpenAPI client migration | Unit tests for typed requests/responses plus source/dependency inspection | Implementation run |
| Disk cache and offline fallback preservation | Existing `ProfileColorCacheTests` and `ColorCatalog` integration behavior inspection | Implementation run |
| Solver parity | `WeightedSquaredErrorParityCorpusTests` replaying the committed backend corpus | This test-writing run |
| Corpus consumption documentation | README update pointing to this fixture and refresh command | Implementation run (README is outside the red-phase allowlist) |
| PR migration notes and parity findings | PR description with reviewed OpenAPI shape and test result evidence | Implementation run |
