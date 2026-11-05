# Issue #39 verification plan

| Criterion | Smallest credible verification | Status in tests-only run |
| --- | --- | --- |
| Typed OpenAPI client covers the app's existing `/api/v1` use | `PaletteAPIClientTests.testFetchColorsUsesV1ProfileQueryAndDecodesEnvelope` checks the colors route, profile query, and response envelope; implementation run must additionally inspect `Package.swift` and generated sources. | Not run: Swift is unavailable. |
| Disk cache, per-server/profile isolation, stale/offline behavior, and cached profile fallback stay intact | Existing `ProfileColorCacheTests` are the focused regression suite; implementation run must execute the specific offline/fallback cases after migration. | Not run: Swift is unavailable. |
| Solver selections match the upstream corpus, including ties | `WeightedSquaredErrorParityCorpusTests.testWeightedSquaredErrorMatchesSharedParityCorpus` replays the committed v1 corpus and checks every candidate score, exclusion, selection, score, and ties. | Not run: Swift is unavailable. |
| Corpus consumption is documented | This document plus `docs/solver-parity-corpus.md` identify the upstream source and refresh procedure. The implementation run must copy the usage note into `README.md`; this tests-only phase may not modify it. | Documentation drafted; README deferred by phase boundary. |
| PR records migration and parity findings | PR-only external evidence: describe generated-client wrapper behavior, any API-shape differences, and corpus results (ties, exclusions, and weights) in the implementation PR body. | Not started: no PR may be opened in this tests-only run. |
