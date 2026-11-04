# Issue #39 verification plan

| Criterion | Smallest credible verification | Status in test-writing phase |
| --- | --- | --- |
| Generated OpenAPI client is adopted for palette/profile reads | `GeneratedOpenAPIClientAdoptionTests` checks that the package declares the generator/runtime and that a generated runtime client is present. `PaletteAPIClientTests` will remain the focused request/auth behavior coverage. | Red: dependencies and generated source are not yet present. |
| Per-server/profile disk cache, offline-stale status, and cached-profile fallback stay intact | Existing `ProfileColorCacheTests` exercise server-scoped reads, persisted profile colors, and corrupt/mismatched cache rejection. The implementation PR must run the focused cache suite unchanged. UI badge presentation requires inspectable human evidence because the SwiftUI catalog is outside the portable core test target. | Not run in this phase. |
| Solver selections exactly match the server corpus, including ties | `WeightedSquaredErrorParityCorpusTests` decodes the committed `priv/parity/v1/corpus.json` fixture and verifies every candidate score, winner, error, and tie set. | To run after adding fixture test. |
| Corpus consumption is documented | README section identifies the vendored fixture and refresh command/source revision. | Not implemented: README is outside the allowed test-writing paths. |
| PR records migration and parity findings | Inspect the PR description after the implementation run. | Human/external evidence required. |

The parity corpus was copied byte-for-byte from `viamin/color_matching` commit `47057afd58f7d46b4d4b740ca7d2d08947774471`, path `priv/parity/v1/corpus.json`. The implementation run should refresh it from the backend commit selected for its generated OpenAPI document.
