# Issue #39 verification plan

This tests-only change records the smallest credible verification for each
acceptance criterion before the generated-client implementation begins.

| Criterion | Verification | Evidence at implementation PR head |
| --- | --- | --- |
| Typed OpenAPI client replaces hand-written `/api/v1` decoding | Focused client contract tests using the generated types and the committed OpenAPI document; inspect `Package.swift` and generated source in review. | `PaletteAPIClientTests` plus generated-client artifacts; human review of generated source. |
| Per-server/profile disk cache, offline-stale badges, and cached profile fallback remain unchanged | Existing focused `ProfileColorCacheTests` cover durable per-server/profile entries. Add a `ColorCatalog` integration test before merging the implementation to exercise a transport failure through the UI-facing catalog state. | `ProfileColorCacheTests` and the new catalog integration test. |
| Solver remains in parity with `color_matching` | Permanent `WeightedSquaredErrorParityCorpusTests` loads the committed corpus and checks selected IDs, scores, exclusions, zero weights, and earliest-wins ties. | `WeightedSquaredErrorParityCorpusTests` and `Fixtures/weighted_squared_error_parity.json`. |
| README explains corpus location and refresh procedure | Inspect the README change against the committed fixture and upstream source. | README review evidence. |
| PR records API-shape and parity findings | Inspect the PR description for generated-client migration notes, `/api/v1` shape changes, and ties/exclusions/weight handling results. | PR description review evidence. |

## Corpus refresh

The committed fixture is consumed directly from
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`.
Refresh it from the corpus published by
[`viamin/color_matching#111`](https://github.com/viamin/color_matching/pull/111),
preserve its case IDs and expected selections exactly, then run
`cd ColorComposerCore && swift test`.

The upstream pull request was unavailable from this isolated test-writing
environment (GitHub returned HTTP 404), so implementation review must compare
this fixture against the upstream committed corpus before it is considered
authoritative.
