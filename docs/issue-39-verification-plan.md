# Issue #39 verification plan

| Criterion | Smallest credible verification | Status in this tests-only run |
| --- | --- | --- |
| Generated OpenAPI client preserves the `/api/v1` calls used by the app | `PaletteAPIClientTests.testFetchColorsUsesV1QueryAndDecodesProfileAndResponses` plus review of generated client wiring | Test added; generated-client wiring requires implementation review. |
| Disk cache, stale offline data, and cached-profile fallback remain available per server/profile | Existing `ProfileColorCacheTests` round-trip and server-scoping tests; app-level fallback remains an implementation review because it is hosted by the macOS target | Existing focused tests retained; implementation review pending. |
| Solver choices remain in parity with `color_matching` | `SolverParityCorpusTests.testWeightedSquaredErrorMatchesCommittedParityCorpus` over the committed upstream corpus | Test added. |
| README explains corpus location and refresh | README “Solver parity corpus” section | Deferred to implementation phase: the tests-only commit allowlist excludes `README.md`. |

The corpus fixture is copied from [`viamin/color_matching` `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json). When the backend solver changes, run `mix parity.generate` in that repository, copy the result over `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`, and run `cd ColorComposerCore && swift test`. Do not edit parity expectations by hand.

The permanent solver test covers the recurring matching flow. The API test is a focused contract test. The generated-client migration itself is structural and needs inspectable review of `Package.swift`, generated source, and `PaletteAPIClient` in the implementation PR.
