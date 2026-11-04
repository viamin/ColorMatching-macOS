# Issue #39 verification plan

| Criterion | Smallest credible verification | Phase |
| --- | --- | --- |
| Typed OpenAPI migration preserves the two consumed endpoints | `PaletteAPIClientTests.testFetchColorsUsesV1ProfileQueryAndDecodesProfileEnvelope` exercises the colors URL, profile query, and response envelope; implementation phase will bind this behavior to the generated client. | Permanent unit/service test |
| Server/profile disk-cache isolation and offline fallback remain intact | Existing `ProfileColorCacheTests` exercise per-server/profile storage and disk round trips. The app-layer fallback state needs implementation-phase verification. | Permanent unit/service test + human inspection |
| Solver matches the backend corpus, including ties and exclusions | `WeightedSquaredErrorParityTests.testV1CorpusMatchesScoresAndSelections` replays the committed v1 backend corpus through the scorer and solver. | Permanent unit/service test |
| Corpus refresh process is discoverable | Add the required README consumption/refresh instructions during the implementation phase; this tests-only phase may not edit README. | Human/documentation evidence |

The committed corpus is copied verbatim from
`viamin/color_matching` at `priv/parity/v1/corpus.json` (SHA-256
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`).
