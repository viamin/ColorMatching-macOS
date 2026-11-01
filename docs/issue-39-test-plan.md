# Issue 39 test plan

This test-only change maps each acceptance criterion to the smallest
inspectable verification before implementation begins.

| Criterion | Verification | Status in this phase |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` | Focused API-client unit tests covering generated request/response adaptation and auth/status behavior | Not implemented: production and package-manifest changes are prohibited in the test-writing phase. |
| Per-server/profile cache, offline-stale badges, cached-profile fallback remain unchanged | Existing `ProfileColorCacheTests` plus a focused `PaletteAPIClient`/cache integration test using a mocked transport | Not run: the generated-client seam does not exist yet. |
| Solver selections match the committed parity corpus, including ties | `WeightedSquaredErrorParityCorpusTests.testSelectionsMatchCommittedParityCorpus` loads the committed JSON fixture and drives the public `CompositionSolver` for one-cell selection | Added; blocked from execution because `swift` is unavailable in this container. |
| README explains corpus consumption and refresh | Human review of the README edit | Deferred: `README.md` is outside the test-writing phase allowlist. The refresh procedure is recorded below for the implementation run. |
| PR records migration notes, API shape changes, and parity findings | PR description with linked test output and upstream corpus revision | Not applicable until the implementation PR is assembled. |

## Parity corpus refresh

The committed fixture is at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`.
It is sourced from `viamin/color_matching#111`. To refresh it, obtain the
upstream corpus at a pinned commit, replace the fixture without changing its
cases or expected winners, and run `swift test` from `ColorComposerCore`.
Record the upstream commit and resulting test output in the PR description.

This environment cannot read the private upstream pull request, so its
published artifact must be copied into this fixture by the implementation run
once the dependency is accessible. The fixture shape intentionally records
selection inputs and expected winning IDs so ties, exclusions, and weight
handling are checked through `CompositionSolver`, not a duplicate scorer.
