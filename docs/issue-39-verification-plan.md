# Issue #39 verification plan

| Acceptance criterion | Smallest credible verification | Phase |
| --- | --- | --- |
| Generated client migrates the palette API while preserving its request contract | Focused `PaletteAPIClient` URL-protocol tests for generated-operation request paths, auth, decoded responses, and API-shape changes | Implementation |
| Per-server/profile cache, offline-stale badges, and cached-profile fallback remain unchanged | Existing cache unit tests plus a focused catalog integration test exercising a failed refresh with seeded disk data | Implementation |
| Solver selections remain in parity with `color_matching` | Permanent unit test decoding the committed `priv/parity/v1/corpus.json` corpus and comparing every candidate score, exclusion, selection, error, and tie | This tests-only change |
| Corpus consumption is documented | README refresh instructions, manually reviewed against the upstream corpus README | Implementation |
| PR records migration and parity findings | PR description reviewed against generated-client diff and test output | Implementation / human evidence |

The corpus fixture is copied from `viamin/color_matching` `priv/parity/v1/corpus.json` (algorithm version 1; SHA-256 `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`). It deliberately covers earliest-index ties, missing positive-weight measurements, zero-weight channels, unknown weights, and all-candidates-excluded cases.
