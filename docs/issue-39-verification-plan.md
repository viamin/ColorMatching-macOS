# Issue #39 verification plan

| Criterion | Smallest credible verification | Phase status |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` while retaining cache/offline fallback behavior | Permanent `PaletteAPIClient` transport tests plus existing `ProfileColorCacheTests`; manual inspection of the generated client against the published OpenAPI document | Awaiting implementation and upstream spec |
| Per-server/profile cache, offline-stale badges, and cached-profile fallback are unchanged | Focused cache unit tests and a manual app inspection of offline-stale UI state | Existing focused tests; app inspection awaits implementation |
| Solver selections match the parity corpus, including ties | `WeightedSquaredErrorParityCorpusTests` loads the committed JSON fixture and runs the public `CompositionSolver` | Added in this test-writing change |
| README explains corpus location and refresh | README review at this commit | Added in this test-writing change |
| PR records generated-client migration notes, API shape changes, and parity results | PR description populated during the implementation/PR run | Awaiting implementation |

The upstream parity artifact named by the issue is `viamin/color_matching#111`. It was not accessible from this environment while this tests-only change was prepared (GitHub returned 404), so the implementation run must replace or byte-verify the vendored fixture before claiming upstream-corpus parity.
