# Issue #39 verification plan

This test-writing PR establishes the durable verification for the generated-client migration and solver parity work. Production changes are intentionally deferred to the implementation phase.

| Criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Generated OpenAPI client serves the existing endpoints | Focused `PaletteAPIClientTests` request/decoding tests plus implementation review of `Package.swift`, generated sources, and the wrapper that preserves the public client contract | Planned for implementation |
| Per-server/profile cache and offline fallback stay intact | Existing focused `ProfileColorCacheTests` and `PaletteAPIClientTests`; implementation review must confirm the generated-client wrapper does not bypass `ColorCatalog` cache/fallback paths | Planned for implementation |
| Solver stays in server parity | `WeightedSquaredErrorParityCorpusTests` replays every committed v1 golden-vector scenario through both the scorer and `CompositionSolver`, including scores, exclusions, selections, errors, and ties | Added in this PR |
| Corpus consumption is documented | README review: name the vendored fixture and upstream refresh command/source | Deferred: README is outside the tests-and-LID-docs allowlist for this phase |
| PR records migration and parity findings | PR description review against generated-client changes and parity-test output | Deferred until implementation PR |

The vendored source of truth is `viamin/color_matching` `priv/parity/v1/corpus.json`, introduced by PR #111. Refresh by copying that committed file without reformatting, then run the Swift test suite. The backend verifies its generated artifact with `mix parity.generate --check`; consumers should use the committed JSON rather than independently recreating its scenarios.
