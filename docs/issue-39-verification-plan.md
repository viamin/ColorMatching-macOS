# Issue #39 verification plan

| Criterion | Verification | Evidence at tests-only PR head |
| --- | --- | --- |
| Generated OpenAPI client replaces handwritten `/api/v1` client | Focused contract test checks that the Swift package declares `swift-openapi-generator` and `swift-openapi-runtime`; existing request tests retain endpoint/auth coverage. | `ColorComposerCore/Tests/ColorComposerCoreTests/GeneratedOpenAPIClientContractTests.swift` (red until implementation) and `PaletteAPIClientTests.swift` |
| Per-server/profile cache, stale badges, cached profile fallback remain intact | Focused unit/service cache tests. UI badge/fallback wiring requires implementation-phase inspection. | `ProfileColorCacheTests.swift`; cached-profile UI evidence: not run in this tests-only phase |
| Solver selections match upstream corpus, including ties | Permanent unit test replays the committed upstream v1 corpus and compares every candidate score, selected index/hex/error, and tie evidence exactly. | `WeightedSquaredErrorParityCorpusTests.swift`, `Fixtures/weighted-squared-error-v1.json` |
| README explains corpus source and refresh | Human-readable documentation review after implementation adds the required README section. | Not run: README is outside the tests-only allowlist |
| PR description records migration, shape changes, parity results | Human/external PR review evidence. | Not run: no PR is opened in this run |
