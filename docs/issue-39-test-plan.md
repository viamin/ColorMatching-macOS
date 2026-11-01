# Issue #39 verification plan

| Criterion | Verification | Status in test-writing phase |
| --- | --- | --- |
| Generated OpenAPI client is adopted without changing API behavior | Focused `PaletteAPIClient` integration tests using a URL-protocol transport: assert generated operation paths, query encoding, decoded DTOs, bearer authorization, and API error mapping. | Deferred to implementation phase; current handwritten client has no generated operation seam. |
| Per-server/profile disk cache and offline-stale/profile fallback remain intact | Permanent unit/service tests for `ProfileColorCache` server/profile scoping plus `AppModel`/catalog collaborator tests for stale badges and cached-profile fallback. | Existing cache tests cover server/profile scoping; implementation phase must add focused fallback assertions through the generated-client adapter. |
| Solver selections match the parity corpus exactly | Permanent unit/service test replays the committed upstream v1 fixture through `WeightedSquaredErrorScorer`, asserting every per-candidate score/exclusion, selected index/hex/error, and tied indices. | Added in `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityTests.swift`. |
| Corpus consumption is documented | Inspectable README usage note naming the upstream corpus path and `mix parity.generate` refresh command. | Deferred: this test-writing phase permits documentation only below `docs/`; implementation phase must update the root README. |
| PR notes record migration, shape changes, and parity findings | Human/external review of the PR description. | Not runnable in this local test-writing phase. |
