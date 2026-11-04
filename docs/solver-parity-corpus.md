# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`
is the committed v1 solver contract from
[`viamin/color_matching`](https://github.com/viamin/color_matching), where it
is generated at `priv/parity/v1/corpus.json`.

Refresh it after the server changes `ColorMatching.WeightedSquaredError` or
its selection semantics:

1. Update the server corpus with `mix parity.generate` and verify it with
   `mix parity.generate --check`.
2. Copy the generated JSON byte-for-byte into the macOS fixture path above.
3. Run `cd ColorComposerCore && swift test --filter SolverParityCorpusTests`.
4. Review every changed scenario, especially the expected scores, excluded
   candidates, selected index, and `tied_indices`.

`SolverParityCorpusTests` decodes and replays every scenario with
`WeightedSquaredErrorScorer`. It checks each candidate score, the selected
palette index and hex color, the error, and the exact tie set. The corpus
captures the contract that missing positive-weight measurements exclude a
candidate, zero-weight channels are ignored, known channel weights scale
squared error, and equal scores select the earliest candidate.

## Criterion verification plan

| Criterion | Smallest credible verification | Test-writing status |
| --- | --- | --- |
| Generated OpenAPI client replaces direct endpoint decoding while retaining cache behavior | Mocked API-contract tests for generated requests plus the existing cache/offline tests | Not yet implemented; requires the generated client implementation. |
| Per-server/profile cache, cached profile fallback, and offline-stale state remain intact | Existing `ProfileColorCacheTests` as regression coverage, plus a focused client-to-cache fallback test | Existing cache coverage is present; integration seam test pending implementation. |
| Solver selections exactly match the server corpus, including ties | Permanent corpus replay unit test | Added in this change. |
| Corpus consumption and refresh process is documented | This document; add a README link during the implementation phase | Added here; root README is outside this test-writing phase's permitted documentation paths. |
| Parity findings are recorded in the PR description | Inspect the generated PR body against corpus results | Human/release evidence, pending PR creation. |
