# Issue #39 verification plan

| Criterion | Smallest credible verification | Status in test-writing phase |
| --- | --- | --- |
| Typed OpenAPI client migrates palette/profile requests | Focused `PaletteAPIClientTests` covering generated-operation request construction and response mapping | Pending implementation |
| Disk cache and offline fallback are unchanged | Existing focused `ProfileColorCacheTests` plus `ColorCatalog` integration coverage | Pending implementation verification |
| Solver matches the backend corpus | `SolverParityCorpusTests` replays the vendored v1 cases and checks every score, selection, error, and tie | Added |
| Corpus consumption is documented | README points to the vendored corpus and the upstream refresh command | Pending implementation (README is outside the test-writing allowlist) |
| PR records migration and parity findings | PR body with generated-client notes, API-shape review, and test output | Pending implementation |

The upstream authority is `viamin/color_matching` at `priv/parity/v1/corpus.json`; refresh the vendored fixture from that file after running `mix parity.generate` in the backend. The complete upstream v1 corpus has 12 scenarios. This first test-writing commit establishes the replay harness and representative v1 cases (distinct errors, tie, exclusion, and zero-weight behavior); the implementation run must vendor the full corpus before approval.
