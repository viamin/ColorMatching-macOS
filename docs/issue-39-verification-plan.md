# Issue #39 verification plan

| Acceptance criterion | Smallest credible verification | Evidence location |
| --- | --- | --- |
| Generated OpenAPI client preserves the palette API contract | Focused service test of the versioned colors operation: method, path, query, authorization, and decoded response | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift` |
| Per-server/profile disk cache, offline-stale status, and cached-profile fallback remain intact | Existing permanent cache and catalog service tests, run after client migration | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift`; `ColorMatchingTests/` catalog tests |
| Solver selections match the parity corpus, including ties | Permanent, data-driven unit test that executes `CompositionSolver` with `WeightedSquaredErrorScorer` for every committed fixture case | `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityCorpusTests.swift` |
| Corpus consumption is documented | README review and committed refresh instructions | `README.md` |
| Generated-client migration notes and API-shape findings are recorded | PR description; human-readable review artifact | PR body (implementation run) |

The canonical backend corpus is `viamin/color_matching#111`. This test-writing
environment cannot read that private upstream pull request (the configured GitHub
proxy returns HTTP 403), so the committed fixture records the known contract cases
and links to its source. The implementation run must replace or verify it against
the published upstream artifact before reporting parity as externally verified.
