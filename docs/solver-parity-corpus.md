# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json`
is an unmodified committed copy of the `color_matching` server corpus at
[`priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).
It is exercised by `WeightedSquaredErrorParityTests` on every `swift test`.

Refresh the fixture only after the server updates its corpus:

1. Run `mix parity.generate --check` in `viamin/color_matching` to verify the
   server corpus is current and deterministic.
2. Replace the committed Swift fixture with the published `priv/parity/v1/corpus.json`.
3. Run `cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityTests`.
4. Review the version stamp and every changed scenario. A version change means
   solver expectations moved and requires an intentional client update.

## Acceptance-criterion verification plan

| Criterion | Smallest credible verification |
| --- | --- |
| Generated OpenAPI client migrates palette requests | Focused `PaletteAPIClient` request/response contract tests (implementation phase). |
| Per-server/profile cache and offline fallback stay intact | Existing `ProfileColorCacheTests` plus focused `ColorCatalog` integration coverage (implementation phase). |
| Solver selections retain server parity | `WeightedSquaredErrorParityTests`, replaying every committed corpus scenario and its per-candidate score, selection, tie, exclusion, and weight expectations. |
| Corpus consumption is documented | This document now; README link/update is reserved for the implementation phase because this red-phase run may only modify test and `docs/` paths. |
| PR records migration findings and parity result | Human/PR evidence after generated-client implementation and full suite execution. |
