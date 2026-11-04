# Issue #39 verification plan

| Criterion | Smallest credible verification | Status in tests-only run |
| --- | --- | --- |
| Generated OpenAPI client serves the palette endpoints | Focused `PaletteAPIClient` request/response tests, including `/api/v1` path, query, and bearer authorization | Not yet added; implementation is outside this tests-only run. |
| Disk cache and offline fallbacks remain unchanged | Existing `ProfileColorCacheTests` plus `ColorCatalog` integration coverage on a macOS host | Requires implementation-run evidence because `ColorCatalog` is app-bound. |
| Solver selection matches the parity corpus, including ties | `SolverParityTests.testWeightedSquaredErrorSelectionsMatchParityCorpus` loads the committed fixture and solves every case through `CompositionSolver` | Added in this run; must be run on a host with Swift. |
| Corpus consumption is documented | README section naming the local fixture, its upstream source, and refresh procedure | Deferred: README is outside the tests-only commit allowlist. |
| PR records API-shape and parity findings | Inspectable PR description with generated-client migration notes and test results | Human/external evidence required when the implementation PR is opened. |

The parity fixture is committed at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`.
It is a local mirror of the corpus planned in
[`viamin/color_matching#111`](https://github.com/viamin/color_matching/pull/111).
Refresh it by replacing the file with the upstream corpus snapshot, retaining cases for
ties, exclusions, and zero-weight channels, then run `swift test` from
`ColorComposerCore`.
