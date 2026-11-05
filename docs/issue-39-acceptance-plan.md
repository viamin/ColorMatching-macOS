# Issue #39 acceptance plan

| Criterion | Smallest credible verification | Current phase |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` without changing the supported API calls | Focused `URLProtocol` contract tests for profile and color requests against the generated transport; inspect the generated source and package dependency at review | Implementation phase |
| Cache remains scoped by server/profile and offline fallback remains visible | Existing permanent `ProfileColorCacheTests` plus focused client/cache integration tests for failed fetches and cached profiles | Implementation phase |
| Solver exactly matches the server corpus, including ties | Permanent `WeightedSquaredErrorParityTests` replays the committed `color_matching` v1 corpus | This test-writing phase |
| Corpus consumption is documented | README review: source location, pinned version/commit, and refresh command | Implementation phase (README is outside this phase's write allowlist) |
| PR records migration notes, shape changes, and parity results | Human review of PR body against generated source and test output | Implementation phase |
