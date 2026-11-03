# Issue #39 test plan

This test-writing change establishes the executable contracts for adopting the
`color_matching` OpenAPI client and its solver parity corpus.

| Criterion | Smallest credible verification | Evidence in this PR phase |
| --- | --- | --- |
| Generated OpenAPI client preserves the palette API contract | Focused `PaletteAPIClient` request/response tests for profile and color endpoints; implementation phase also compiles the generated target | Existing `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift`; generated-client build coverage is pending the implementation phase because `Package.swift` is outside the test-writing allowlist. |
| Per-server/profile disk cache, offline-stale badges, and cached-profile fallback remain intact | Focused cache/catalog tests for server scoping and fallback behavior | Existing `ProfileColorCacheTests.swift`; app-level catalog coverage should be run after the generated-client migration. |
| Solver selections match the server corpus, including ties, exclusions, and weights | Permanent focused parity fixture test | `ColorComposerCore/Tests/ColorComposerCoreTests/ParityCorpusTests.swift` replays every v1 scenario and checks scorer output plus solver selection. |
| Corpus consumption is documented | Inspect the README refresh instructions | Pending implementation phase: the repository root README is deliberately not editable during this tests-only run. |

The committed fixture is copied verbatim from
[`viamin/color_matching` `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).
The implementation phase must add the README refresh command and retain this
file as the input loaded by `ParityCorpusTests`.
