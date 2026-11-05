# Issue #39 verification plan

| Criterion | Smallest credible verification | Current evidence |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` | Focused `PaletteAPIClient` request/response contract tests against the generated client adapter | Implementation-phase work; no public OpenAPI document is available in this environment. |
| Per-server/profile caching and offline fallbacks remain intact | Existing permanent `ProfileColorCacheTests` plus app-layer inspection for offline-stale badge and cached-profile fallback | Existing cache tests cover server/profile scoping; app-layer external evidence is required. |
| Solver matches parity corpus, including ties | Permanent `SolverParityCorpusTests` loads the committed JSON corpus and runs the production `CompositionSolver` | Added in this tests-only change. |
| Corpus consumption is documented | README review after the backend corpus has a stable revision/path | Implementation-phase documentation work. |
| PR records migration/parity findings | Human review of PR description | External evidence; cannot be settled by Swift tests. |

## Corpus refresh procedure

The committed fixture is `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`.
When `viamin/color_matching#111` is accessible, replace this fixture verbatim with its published corpus, retain its source revision in the fixture metadata, and run `cd ColorComposerCore && swift test --filter SolverParityCorpusTests`.

The fixture must retain cases covering weighted selections, earliest-wins ties, missing active-channel exclusions, zero-weight handling, and the all-excluded outcome.
