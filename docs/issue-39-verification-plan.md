# Issue 39 verification plan

This test-writing change commits the upstream solver corpus at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json`.
It is an exact copy of `viamin/color_matching` `priv/parity/v1/corpus.json`
(algorithm version 1, SHA-256
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`).

| Criterion | Smallest credible verification | Status in this test-writing change |
| --- | --- | --- |
| Generated OpenAPI client preserves `/api/v1` client behavior | Focused `PaletteAPIClientTests` request/response contract tests, then inspect the generated source and package dependencies in the implementation PR | Awaiting implementation |
| Per-server/profile disk cache and offline fallback stay intact | Existing focused cache tests, including `ProfileColorCacheTests.testTwoServersKeepSeparateEntriesForTheSameProfileID` and `testAllEntriesOnlyReturnsTheRequestingServersEntries`; implementation PR must run an integration exercise of the UI catalog fallback | Existing unit coverage; integration evidence awaiting implementation |
| Solver matches the server parity contract | Permanent `WeightedSquaredErrorParityTests.testReplaysCommittedServerParityCorpus`, which checks every candidate score, selected color/error, and earliest-wins tie evidence; it also invokes `CompositionSolver` where a complete target can be represented by source grids | Added; test execution awaiting Swift toolchain |
| README explains corpus refresh | Human inspection of the README change: name the upstream path and `mix parity.generate` / fixture-copy refresh workflow | Awaiting implementation; README is intentionally outside the test-writing allowlist |
| PR description records migration and parity findings | Inspect the final PR description against the corpus results and OpenAPI diff | Awaiting implementation PR |

The test deliberately does not recreate solver formulas or expected selections.
It decodes the committed server-owned fixture, so a server contract change is visible
as a fixture diff and a replay failure.
